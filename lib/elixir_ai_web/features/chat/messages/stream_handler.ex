defmodule ElixirAi.ChatRunner.StreamHandler do
  require Logger
  import ElixirAi.ChatRunner.OutboundHelpers

  defp all_tools(state) do
    state.server_tools ++ state.liveview_tools ++ state.page_tools
  end

  def handle({:start_new_ai_response, id}, state) do
    starting_response = %{
      id: id,
      reasoning_content: "",
      content: "",
      tool_calls: [],
      started_at: System.monotonic_time(:millisecond)
    }

    broadcast_ui(state.name, {:start_ai_response_stream, starting_response})

    {:noreply,
     %{state | streaming_response: starting_response, current_status: :generating_ai_response}}
  end

  def handle({:ai_reasoning_chunk, _id, reasoning_content}, state) do
    broadcast_ui(state.name, {:reasoning_chunk_content, reasoning_content})

    {:noreply,
     %{
       state
       | streaming_response: %{
           state.streaming_response
           | reasoning_content: state.streaming_response.reasoning_content <> reasoning_content
         }
     }}
  end

  def handle({:ai_text_chunk, _id, text_content}, state) do
    broadcast_ui(state.name, {:text_chunk_content, text_content})

    {:noreply,
     %{
       state
       | streaming_response: %{
           state.streaming_response
           | content: state.streaming_response.content <> text_content
         }
     }}
  end

  def handle({:ai_text_stream_finish, id}, state) do
    Logger.info(
      "AI stream finished for id #{state.streaming_response.id}, waiting for usage chunk"
    )

    # Mark content as done so `:ai_usage` knows elapsed time. Also schedule a
    # fallback in case the provider never sends a usage chunk (e.g. proxies that
    # strip the trailing SSE frame).
    updated =
      Map.put(state.streaming_response, :content_finished_at, System.monotonic_time(:millisecond))

    Process.send_after(self(), {:finalize_response, id}, 1_500)

    {:noreply, %{state | streaming_response: updated}}
  end

  def handle({:ai_usage, prompt_tokens, completion_tokens}, state) do
    with resp when not is_nil(resp) <- state.streaming_response,
         finished_at when not is_nil(finished_at) <- resp[:content_finished_at] do
      elapsed_s = max(finished_at - resp.started_at, 1) / 1_000
      tps = Float.round(completion_tokens / elapsed_s, 1)

      valid_tool_calls =
        Enum.filter(resp.tool_calls, fn tc ->
          is_binary(tc.arguments) and match?({:ok, _}, Jason.decode(tc.arguments))
        end)

      final_message = %{
        role: :assistant,
        content: resp.content,
        reasoning_content: resp.reasoning_content,
        tool_calls: valid_tool_calls,
        input_tokens: prompt_tokens,
        output_tokens: completion_tokens,
        tokens_per_second: tps
      }

      store_message(state.conversation_id, state.name, final_message)
      broadcast_ui(state.name, {:end_ai_response, final_message})

      {:noreply,
       %{
         state
         | streaming_response: nil,
           ai_task_pid: nil,
           current_status: :idle,
           messages: state.messages ++ [final_message]
       }}
    else
      _ -> {:noreply, state}
    end
  end

  def handle(
        {:ai_tool_call_start, _id, {tool_name, tool_args_start, tool_index, tool_call_id}},
        state
      ) do
    Logger.info("AI started tool call #{tool_name}")

    new_tool_call = %{
      name: tool_name,
      arguments: tool_args_start,
      index: tool_index,
      id: tool_call_id
    }

    new_streaming_response = %{
      state.streaming_response
      | tool_calls: state.streaming_response.tool_calls ++ [new_tool_call]
    }

    broadcast_ui(state.name, {:streaming_tool_call_start, new_tool_call})

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle({:ai_tool_call_middle, _id, {tool_args_diff, tool_index}}, state) do
    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          Enum.map(state.streaming_response.tool_calls, fn
            %{arguments: existing_args, index: ^tool_index} = tool_call ->
              %{tool_call | arguments: existing_args <> tool_args_diff}

            other ->
              other
          end)
    }

    broadcast_ui(state.name, {:streaming_tool_args_chunk, tool_index, tool_args_diff})

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle({:ai_tool_call_end, id}, state) do
    raw_tool_calls = Enum.map(state.streaming_response.tool_calls, &Map.delete(&1, :index))

    {valid_tool_calls, dropped_count} = filter_valid_tool_calls(raw_tool_calls, state)

    if dropped_count > 0 do
      Logger.info(
        "Dropped #{dropped_count} malformed tool call(s) for conversation #{state.name} (#{state.conversation_id})"
      )
    end

    tool_request_message = build_tool_request_message(state.streaming_response, valid_tool_calls)

    if valid_tool_calls == [] do
      finalize_as_plain_text_response(state, tool_request_message)
    else
      {failed_call_messages, dispatchable_calls} = classify_tool_calls(valid_tool_calls, state)
      persist_tool_call_cycle(state, tool_request_message, failed_call_messages)
      dispatch_tool_calls(dispatchable_calls, id)

      pending_call_ids = Enum.map(dispatchable_calls, fn {_tool, tc, _args} -> tc.id end)

      {:noreply,
       %{
         state
         | messages: state.messages ++ [tool_request_message] ++ failed_call_messages,
           streaming_response: nil,
           pending_tool_calls: pending_call_ids,
           current_status: :awaiting_tools
       }}
    end
  end

  def handle({:tool_response_chunk, _id, tool_call_id, chunk}, state) do
    broadcast_ui(state.name, {:tool_result_chunk, tool_call_id, chunk})
    new_outputs = Map.update(state.streaming_tool_outputs, tool_call_id, chunk, &(&1 <> chunk))
    {:noreply, %{state | streaming_tool_outputs: new_outputs}}
  end

  def handle({:tool_response_done, _id, tool_call_id, exit_code, elapsed_ms}, state) do
    buffered = Map.get(state.streaming_tool_outputs, tool_call_id, "")

    formatted =
      ElixirAi.CommandRunner.Presentation.format(%{
        stdout: buffered,
        stderr: "",
        exit_code: exit_code,
        duration_ms: elapsed_ms
      })

    new_message = %{
      role: :tool,
      content: inspect({:ok, formatted}, printable_limit: :infinity),
      tool_call_id: tool_call_id
    }

    store_message(state.conversation_id, state.name, new_message)
    broadcast_ui(state.name, {:one_tool_finished, new_message})

    new_pending = Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)
    new_outputs = Map.delete(state.streaming_tool_outputs, tool_call_id)

    if new_pending == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(state.messages ++ [new_message], state.system_prompt),
        all_tools(state),
        state.provider,
        state.tool_choice,
        state.response_format
      )
    end

    {:noreply,
     %{
       state
       | pending_tool_calls: new_pending,
         streaming_tool_outputs: new_outputs,
         streaming_response: nil,
         current_status:
           if(new_pending == [], do: :generating_ai_response, else: :awaiting_tools),
         messages: state.messages ++ [new_message]
     }}
  end

  def handle({:tool_response, _id, tool_call_id, {:error, reason}}, state) do
    error_content = if is_binary(reason), do: reason, else: inspect(reason)

    new_message = %{
      role: :tool,
      content: error_content,
      tool_call_id: tool_call_id,
      is_error: true
    }

    store_message(state.conversation_id, state.name, new_message)
    broadcast_ui(state.name, {:one_tool_finished, new_message})

    new_pending_tool_calls =
      Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)

    if new_pending_tool_calls == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(state.messages ++ [new_message], state.system_prompt),
        all_tools(state),
        state.provider,
        state.tool_choice,
        state.response_format
      )
    end

    {:noreply,
     %{
       state
       | pending_tool_calls: new_pending_tool_calls,
         streaming_response: nil,
         current_status:
           if(new_pending_tool_calls == [], do: :generating_ai_response, else: :awaiting_tools),
         messages: state.messages ++ [new_message]
     }}
  end

  def handle({:tool_response, _id, tool_call_id, result}, state) do
    new_message = %{
      role: :tool,
      content: inspect(result, printable_limit: :infinity),
      tool_call_id: tool_call_id
    }

    store_message(state.conversation_id, state.name, new_message)
    broadcast_ui(state.name, {:one_tool_finished, new_message})

    new_pending_tool_calls =
      Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)

    if new_pending_tool_calls == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(state.messages ++ [new_message], state.system_prompt),
        all_tools(state),
        state.provider,
        state.tool_choice,
        state.response_format
      )
    end

    {:noreply,
     %{
       state
       | pending_tool_calls: new_pending_tool_calls,
         streaming_response: nil,
         current_status:
           if(new_pending_tool_calls == [], do: :generating_ai_response, else: :awaiting_tools),
         messages: state.messages ++ [new_message]
     }}
  end

  def handle({:ai_request_error, reason}, state) do
    Logger.error("AI request error: #{inspect(reason)}")
    error_message = %{role: :error, content: format_error(reason)}
    broadcast_ui(state.name, {:inline_error_message, error_message})
    {:noreply, %{state | streaming_response: nil, pending_tool_calls: [], current_status: :error}}
  end

  defp format_error(%{"message" => msg}), do: msg

  defp format_error("proxy error" <> _),
    do: "Could not connect to AI provider. Please check your proxy and provider settings."

  defp format_error(%{__struct__: _, reason: :timeout}), do: "Request timed out"
  defp format_error(%{__struct__: mod, reason: r}), do: "#{inspect(mod)}: #{inspect(r)}"
  defp format_error(msg) when is_binary(msg), do: msg
  defp format_error(reason), do: inspect(reason)

  # Phase 1 — strip out tool calls with malformed/incomplete JSON arguments.
  # These are silently dropped; they never executed and have no recovery value.
  defp filter_valid_tool_calls(raw_tool_calls, state) do
    {reversed_valid, dropped_count} =
      Enum.reduce(raw_tool_calls, {[], 0}, fn tc, {valid, dropped} ->
        case Jason.decode(tc.arguments) do
          {:ok, _} ->
            {[tc | valid], dropped}

          {:error, decode_error} ->
            Logger.warning("""
            Dropping tool call — arguments are not valid JSON (likely truncated by stop)
              conversation: #{state.name} (#{state.conversation_id})
              tool:         #{tc.name}
              id:           #{tc.id}
              error:        #{inspect(decode_error)}
              args:         #{tc.arguments}
            """)

            {valid, dropped + 1}
        end
      end)

    {Enum.reverse(reversed_valid), dropped_count}
  end

  defp build_tool_request_message(streaming_response, valid_tool_calls) do
    %{
      role: :assistant,
      content: streaming_response.content,
      reasoning_content: streaming_response.reasoning_content,
      tool_calls: valid_tool_calls
    }
  end

  # Phase 2 — classify each valid tool call without executing anything.
  # Separates calls with unknown tool names (immediate error) from dispatchable
  # ones. Must complete before persist so the full failed_call_messages list is known.
  defp classify_tool_calls(valid_tool_calls, state) do
    {reversed_failed, reversed_dispatchable} =
      Enum.reduce(valid_tool_calls, {[], []}, fn tool_call, {failed, dispatchable} ->
        {:ok, decoded_args} = Jason.decode(tool_call.arguments)

        case Enum.find(all_tools(state), fn t -> t.name == tool_call.name end) do
          nil ->
            error_msg = "No tool definition found for #{tool_call.name}"
            Logger.error(error_msg)
            error_response = %{role: :tool, content: error_msg, tool_call_id: tool_call.id, is_error: true}
            {[error_response | failed], dispatchable}

          tool ->
            {failed, [{tool, tool_call, decoded_args} | dispatchable]}
        end
      end)

    {Enum.reverse(reversed_failed), Enum.reverse(reversed_dispatchable)}
  end

  # Phase 3 — persist the assistant message and ALL tool_calls_request_messages rows
  # before any tool runs. A fast auto-allowed tool can complete and attempt to write
  # its tool_response_messages row immediately; the FK constraint requires the parent
  # row to already exist in tool_calls_request_messages.
  defp persist_tool_call_cycle(state, tool_request_message, failed_call_messages) do
    store_message(state.conversation_id, state.name, [tool_request_message] ++ failed_call_messages)
    broadcast_ui(state.name, {:tool_request_message, tool_request_message})
    Enum.each(failed_call_messages, &broadcast_ui(state.name, {:one_tool_finished, &1}))
  end

  # Phase 4 — dispatch tools only after the DB write has committed.
  defp dispatch_tool_calls(dispatchable_calls, stream_id) do
    Enum.each(dispatchable_calls, fn {tool, tool_call, decoded_args} ->
      tool.run_function.(stream_id, tool_call.id, decoded_args)
    end)
  end

  defp finalize_as_plain_text_response(state, final_message) do
    store_message(state.conversation_id, state.name, final_message)
    broadcast_ui(state.name, {:end_ai_response, final_message})

    {:noreply,
     %{
       state
       | messages: state.messages ++ [final_message],
         streaming_response: nil,
         pending_tool_calls: [],
         current_status: :idle,
         ai_task_pid: nil
     }}
  end

  # Fallback fired ~1.5 s after finish_reason: stop for providers that never
  # send a usage chunk. No-op if the usage chunk already finalized the message.
  def handle({:finalize_response, _id}, %{streaming_response: nil} = state) do
    {:noreply, state}
  end

  def handle({:finalize_response, _id}, state) do
    resp = state.streaming_response

    if resp[:content_finished_at] do
      Logger.info("Finalizing response via fallback (no usage chunk received)")

      valid_tool_calls =
        Enum.filter(resp.tool_calls, fn tc ->
          is_binary(tc.arguments) and match?({:ok, _}, Jason.decode(tc.arguments))
        end)

      final_message = %{
        role: :assistant,
        content: resp.content,
        reasoning_content: resp.reasoning_content,
        tool_calls: valid_tool_calls
      }

      store_message(state.conversation_id, state.name, final_message)
      broadcast_ui(state.name, {:end_ai_response, final_message})

      {:noreply,
       %{
         state
         | streaming_response: nil,
           ai_task_pid: nil,
           current_status: :idle,
           messages: state.messages ++ [final_message]
       }}
    else
      {:noreply, state}
    end
  end
end
