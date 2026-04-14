defmodule ElixirAi.ChatRunner.StreamHandler do
  require Logger
  import ElixirAi.ChatRunner.OutboundHelpers

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

      final_message = %{
        role: :assistant,
        content: resp.content,
        reasoning_content: resp.reasoning_content,
        tool_calls: resp.tool_calls,
        input_tokens: prompt_tokens,
        output_tokens: completion_tokens,
        tokens_per_second: tps
      }

      broadcast_ui(state.name, {:end_ai_response, final_message})
      store_message(state.conversation_id, state.name, final_message)

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

    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          state.streaming_response.tool_calls ++
            [
              %{
                name: tool_name,
                arguments: tool_args_start,
                index: tool_index,
                id: tool_call_id
              }
            ]
    }

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

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle({:ai_tool_call_end, id}, state) do
    tool_request_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: Enum.map(state.streaming_response.tool_calls, &Map.delete(&1, :index))
    }

    broadcast_ui(state.name, {:tool_request_message, tool_request_message})

    {failed_call_messages, pending_call_ids} =
      Enum.reduce(state.streaming_response.tool_calls, {[], []}, fn tool_call,
                                                                    {failed, pending} ->
        with {:ok, decoded_args} <- Jason.decode(tool_call.arguments),
             tool when not is_nil(tool) <-
               Enum.find(state.server_tools ++ state.liveview_tools ++ state.page_tools, fn t ->
                 t.name == tool_call.name
               end) do
          tool.run_function.(id, tool_call.id, decoded_args)
          {failed, [tool_call.id | pending]}
        else
          {:error, e} ->
            error_msg = "Failed to decode tool arguments: #{inspect(e)}"
            Logger.error("Tool call #{tool_call.name} failed: #{error_msg}")
            {[%{role: :tool, content: error_msg, tool_call_id: tool_call.id} | failed], pending}

          nil ->
            error_msg = "No tool definition found for #{tool_call.name}"
            Logger.error(error_msg)
            {[%{role: :tool, content: error_msg, tool_call_id: tool_call.id} | failed], pending}
        end
      end)

    store_message(
      state.conversation_id,
      state.name,
      [tool_request_message] ++ failed_call_messages
    )

    {:noreply,
     %{
       state
       | messages: state.messages ++ [tool_request_message] ++ failed_call_messages,
         streaming_response: nil,
         pending_tool_calls: pending_call_ids,
         current_status: :awaiting_tools
     }}
  end

  def handle({:tool_response, _id, tool_call_id, result}, state) do
    new_message = %{role: :tool, content: inspect(result), tool_call_id: tool_call_id}

    broadcast_ui(state.name, {:one_tool_finished, new_message})
    store_message(state.conversation_id, state.name, new_message)

    new_pending_tool_calls =
      Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)

    if new_pending_tool_calls == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(state.messages ++ [new_message], state.system_prompt),
        state.server_tools ++ state.liveview_tools ++ state.page_tools,
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
    broadcast_ui(state.name, {:ai_request_error, reason})
    {:noreply, %{state | streaming_response: nil, pending_tool_calls: [], current_status: :error}}
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

      final_message = %{
        role: :assistant,
        content: resp.content,
        reasoning_content: resp.reasoning_content,
        tool_calls: resp.tool_calls
      }

      broadcast_ui(state.name, {:end_ai_response, final_message})
      store_message(state.conversation_id, state.name, final_message)

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
