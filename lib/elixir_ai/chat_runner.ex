defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  alias ElixirAi.{AiTools, Conversation, Message}
  import ElixirAi.PubsubTopics

  defp via(name), do: {:via, Horde.Registry, {ElixirAi.ChatRegistry, name}}

  def new_user_message(name, text_content, opts \\ []) do
    tool_choice = Keyword.get(opts, :tool_choice)
    GenServer.cast(via(name), {:user_message, text_content, tool_choice})
  end

  def set_allowed_tools(name, tool_names) when is_list(tool_names) do
    GenServer.call(via(name), {:set_allowed_tools, tool_names})
  end

  def set_tool_choice(name, tool_choice) when tool_choice in ["auto", "none", "required"] do
    GenServer.call(via(name), {:set_tool_choice, tool_choice})
  end

  def register_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:register_liveview_pid, liveview_pid})
  end

  def deregister_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:deregister_liveview_pid, liveview_pid})
  end

  @spec get_conversation(String.t()) :: any()
  def get_conversation(name) do
    GenServer.call(via(name), :get_conversation)
  end

  def get_streaming_response(name) do
    GenServer.call(via(name), :get_streaming_response)
  end

  def start_link(name: name) do
    GenServer.start_link(__MODULE__, name, name: via(name))
  end

  def init(name) do
    Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversation_message_topic(name))

    messages =
      case Conversation.find_id(name) do
        {:ok, conv_id} ->
          Message.load_for_conversation(conv_id, topic: conversation_message_topic(name))

        _ ->
          []
      end

    last_message = List.last(messages)

    provider =
      case Conversation.find_provider(name) do
        {:ok, p} -> p
        _ -> nil
      end

    allowed_tools =
      case Conversation.find_allowed_tools(name) do
        {:ok, tools} -> tools
        _ -> AiTools.all_tool_names()
      end

    tool_choice =
      case Conversation.find_tool_choice(name) do
        {:ok, tc} -> tc
        _ -> "auto"
      end

    server_tools = AiTools.build_server_tools(self(), allowed_tools)
    liveview_tools = AiTools.build_liveview_tools(self(), allowed_tools)

    if last_message && last_message.role == :user do
      Logger.info(
        "Last message role was #{last_message.role}, requesting AI response for conversation #{name}"
      )

      broadcast_ui(name, :recovery_restart)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages,
        server_tools ++ liveview_tools,
        provider,
        tool_choice
      )
    end

    {:ok,
     %{
       name: name,
       messages: messages,
       streaming_response: nil,
       pending_tool_calls: [],
       allowed_tools: allowed_tools,
       tool_choice: tool_choice,
       server_tools: server_tools,
       liveview_tools: liveview_tools,
       provider: provider,
       liveview_pids: %{}
     }}
  end

  def handle_cast({:user_message, text_content, tool_choice_override}, state) do
    effective_tool_choice = tool_choice_override || state.tool_choice
    new_message = %{role: :user, content: text_content, tool_choice: tool_choice_override}
    broadcast_ui(state.name, {:user_chat_message, new_message})
    store_message(state.name, new_message)
    new_state = %{state | messages: state.messages ++ [new_message]}

    ElixirAi.ChatUtils.request_ai_response(
      self(),
      new_state.messages,
      state.server_tools ++ state.liveview_tools,
      state.provider,
      effective_tool_choice
    )

    {:noreply, new_state}
  end

  @ai_stream_events [
    :ai_text_chunk,
    :ai_reasoning_chunk,
    :ai_text_stream_finish,
    :ai_tool_call_start,
    :ai_tool_call_middle,
    :ai_tool_call_end,
    :tool_response
  ]

  def handle_info({:start_new_ai_response, id}, state) do
    starting_response = %{id: id, reasoning_content: "", content: "", tool_calls: []}
    broadcast_ui(state.name, {:start_ai_response_stream, starting_response})

    {:noreply, %{state | streaming_response: starting_response}}
  end

  def handle_info(
        msg,
        %{streaming_response: %{id: current_id}} = state
      )
      when is_tuple(msg) and tuple_size(msg) in [2, 3] and
             elem(msg, 0) in @ai_stream_events and elem(msg, 1) != current_id do
    Logger.warning(
      "Received #{elem(msg, 0)} for id #{inspect(elem(msg, 1))} but current streaming response is for id #{inspect(current_id)}"
    )

    {:noreply, state}
  end

  def handle_info({:ai_reasoning_chunk, _id, reasoning_content}, state) do
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

  def handle_info({:ai_text_chunk, _id, text_content}, state) do
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

  def handle_info({:ai_text_stream_finish, _id}, state) do
    Logger.info(
      "AI stream finished for id #{state.streaming_response.id}, broadcasting end of AI response"
    )

    final_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: state.streaming_response.tool_calls
    }

    broadcast_ui(state.name, {:end_ai_response, final_message})
    store_message(state.name, final_message)

    {:noreply,
     %{
       state
       | streaming_response: nil,
         messages: state.messages ++ [final_message]
     }}
  end

  def handle_info(
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

  def handle_info({:ai_tool_call_middle, _id, {tool_args_diff, tool_index}}, state) do
    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          Enum.map(state.streaming_response.tool_calls, fn
            %{
              arguments: existing_args,
              index: ^tool_index
            } = tool_call ->
              %{
                tool_call
                | arguments: existing_args <> tool_args_diff
              }

            other ->
              other
          end)
    }

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle_info({:ai_tool_call_end, id}, state) do
    tool_request_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: state.streaming_response.tool_calls
    }

    broadcast_ui(state.name, {:tool_request_message, tool_request_message})

    {failed_call_messages, pending_call_ids} =
      Enum.reduce(state.streaming_response.tool_calls, {[], []}, fn tool_call,
                                                                    {failed, pending} ->
        with {:ok, decoded_args} <- Jason.decode(tool_call.arguments),
             tool when not is_nil(tool) <-
               Enum.find(state.server_tools ++ state.liveview_tools, fn t ->
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

    store_message(state.name, [tool_request_message] ++ failed_call_messages)

    {:noreply,
     %{
       state
       | messages: state.messages ++ [tool_request_message] ++ failed_call_messages,
         pending_tool_calls: pending_call_ids
     }}
  end

  def handle_info({:tool_response, _id, tool_call_id, result}, state) do
    new_message = %{role: :tool, content: inspect(result), tool_call_id: tool_call_id}

    broadcast_ui(state.name, {:one_tool_finished, new_message})
    store_message(state.name, new_message)

    new_pending_tool_calls =
      Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)

    new_streaming_response =
      case new_pending_tool_calls do
        [] ->
          nil

        _ ->
          state.streaming_response
      end

    if new_pending_tool_calls == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        state.messages ++ [new_message],
        state.server_tools ++ state.liveview_tools,
        state.provider,
        state.tool_choice
      )
    end

    {:noreply,
     %{
       state
       | pending_tool_calls: new_pending_tool_calls,
         streaming_response: new_streaming_response,
         messages: state.messages ++ [new_message]
     }}
  end

  def handle_info({:db_error, reason}, state) do
    broadcast_ui(state.name, {:db_error, reason})
    {:noreply, state}
  end

  def handle_info({:sql_result_validation_error, error}, state) do
    Logger.error("ChatRunner received sql_result_validation_error: #{inspect(error)}")
    broadcast_ui(state.name, {:db_error, "Schema validation error: #{inspect(error)}"})
    {:noreply, state}
  end

  def handle_info({:store_message, _name, _message}, state) do
    {:noreply, state}
  end

  def handle_info({:ai_request_error, reason}, state) do
    Logger.error("AI request error: #{inspect(reason)}")
    broadcast_ui(state.name, {:ai_request_error, reason})
    {:noreply, %{state | streaming_response: nil, pending_tool_calls: []}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.liveview_pids, pid) do
      ^ref ->
        Logger.info("ChatRunner #{state.name}: LiveView #{inspect(pid)} disconnected")
        {:noreply, %{state | liveview_pids: Map.delete(state.liveview_pids, pid)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_streaming_response, _from, state) do
    {:reply, state.streaming_response, state}
  end

  def handle_call(:get_liveview_pids, _from, state) do
    {:reply, Map.keys(state.liveview_pids), state}
  end

  def handle_call({:register_liveview_pid, liveview_pid}, _from, state) do
    ref = Process.monitor(liveview_pid)
    {:reply, :ok, %{state | liveview_pids: Map.put(state.liveview_pids, liveview_pid, ref)}}
  end

  def handle_call({:deregister_liveview_pid, liveview_pid}, _from, state) do
    case Map.pop(state.liveview_pids, liveview_pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, new_pids} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | liveview_pids: new_pids}}
    end
  end

  def handle_call({:set_tool_choice, tool_choice}, _from, state) do
    Conversation.update_tool_choice(state.name, tool_choice)
    {:reply, :ok, %{state | tool_choice: tool_choice}}
  end

  def handle_call({:set_allowed_tools, tool_names}, _from, state) do
    Conversation.update_allowed_tools(state.name, tool_names)
    server_tools = AiTools.build_server_tools(self(), tool_names)
    liveview_tools = AiTools.build_liveview_tools(self(), tool_names)

    {:reply, :ok,
     %{
       state
       | allowed_tools: tool_names,
         server_tools: server_tools,
         liveview_tools: liveview_tools
     }}
  end

  defp broadcast_ui(name, msg),
    do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, chat_topic(name), msg)

  defp store_message(name, messages) when is_list(messages) do
    Enum.each(messages, &store_message(name, &1))
    messages
  end

  defp store_message(name, message) do
    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      conversation_message_topic(name),
      {:store_message, name, message}
    )

    message
  end
end
