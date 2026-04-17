defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  alias ElixirAi.{AiTools, Conversation}
  import ElixirAi.PubsubTopics
  import ElixirAi.ChatRunner.OutboundHelpers

  alias ElixirAi.ChatRunner.{
    ApprovalTracker,
    ConversationCalls,
    ErrorHandler,
    LiveviewSession,
    Recovery,
    StreamHandler,
    ToolConfig
  }

  @ai_stream_events [
    :ai_text_chunk,
    :ai_reasoning_chunk,
    :ai_text_stream_finish,
    :ai_tool_call_start,
    :ai_tool_call_middle,
    :ai_tool_call_end,
    :tool_response,
    :tool_response_chunk,
    :tool_response_done
  ]

  defp via(name), do: {:via, Horde.Registry, {ElixirAi.ChatRegistry, name}}

  def new_user_message(name, text_content, opts \\ []) do
    tool_choice = Keyword.get(opts, :tool_choice)
    GenServer.cast(via(name), {:conversation, {:user_message, text_content, tool_choice}})
  end

  def ai_turn(name) do
    GenServer.cast(via(name), {:conversation, :ai_turn})
  end

  def set_allowed_tools(name, tool_names) when is_list(tool_names) do
    GenServer.call(via(name), {:tool_config, {:set_allowed_tools, tool_names}})
  end

  def set_tool_choice(name, tool_choice) when tool_choice in ["auto", "none", "required"] do
    GenServer.call(via(name), {:tool_config, {:set_tool_choice, tool_choice}})
  end

  def set_provider(name, provider_id) when is_binary(provider_id) do
    GenServer.call(via(name), {:tool_config, {:set_provider, provider_id}})
  end

  def set_response_format(name, response_format) do
    GenServer.call(via(name), {:tool_config, {:set_response_format, response_format}})
  end

  def register_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:session, {:register_liveview_pid, liveview_pid}})
  end

  def register_liveview_pid_direct(runner_pid, liveview_pid)
      when is_pid(runner_pid) and is_pid(liveview_pid) do
    GenServer.call(runner_pid, {:session, {:register_liveview_pid, liveview_pid}})
  end

  def deregister_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:session, {:deregister_liveview_pid, liveview_pid}})
  end

  def register_page_tools(name, page_tools) when is_list(page_tools) do
    GenServer.call(via(name), {:session, {:register_page_tools, page_tools}})
  end

  def get_conversation(name) do
    GenServer.call(via(name), {:conversation, :get_conversation})
  end

  def get_status(name) do
    GenServer.call(via(name), {:session, :get_status})
  end

  def get_streaming_response(name) do
    GenServer.call(via(name), {:conversation, :get_streaming_response})
  end

  def approval_decision(name, ref, decision) do
    GenServer.cast(via(name), {:approval_decision, ref, decision})
  end

  def stop_conversation(name) do
    GenServer.cast(via(name), :stop_conversation)
  end

  def get_pending_approvals(name) do
    GenServer.call(via(name), {:session, :get_pending_approvals})
  end

  def start_link(name: name) do
    GenServer.start_link(__MODULE__, name, name: via(name))
  end

  def init(name) do
    Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversation_message_topic(name))
    Phoenix.PubSub.subscribe(ElixirAi.PubSub, "mcp_servers")
    :pg.join(ElixirAi.RunnerPG, {:runner, name}, self())

    {:ok,
     %{
       name: name,
       conversation_id: nil,
       messages: [],
       system_prompt: nil,
       streaming_response: nil,
       pending_tool_calls: [],
       streaming_tool_outputs: %{},
       pending_approvals: %{},
       allowed_tools: AiTools.all_tool_names(),
       tool_choice: "auto",
       server_tools: [],
       liveview_tools: [],
       mcp_tools: [],
       page_tools: [],
       provider: nil,
       response_format: nil,
       liveview_pids: %{},
       current_status: :initial_startup,
       ai_task_pid: nil,
       stopped: false
     }, {:continue, :load_from_db}}
  end

  def handle_continue(:load_from_db, state) do
    result = Recovery.load_and_resume(state)
    with_status_broadcast(state, result)
  end

  def handle_cast({:conversation, {:user_message, _, _} = inner}, state) do
    state =
      if state.stopped do
        Conversation.set_stopped(state.name, false)
        %{state | stopped: false}
      else
        state
      end

    with_status_broadcast(state, ConversationCalls.handle_cast(inner, state))
  end

  def handle_cast({:conversation, :ai_turn}, state) do
    state =
      if state.stopped do
        Conversation.set_stopped(state.name, false)
        %{state | stopped: false}
      else
        state
      end

    with_status_broadcast(state, ConversationCalls.handle_cast(:ai_turn, state))
  end

  def handle_cast({:conversation, inner}, state) do
    with_status_broadcast(state, ConversationCalls.handle_cast(inner, state))
  end

  def handle_cast(:stop_conversation, state) do
    if state.ai_task_pid && Process.alive?(state.ai_task_pid) do
      Process.exit(state.ai_task_pid, :kill)
    end

    Enum.each(state.pending_approvals, fn {ref, %{pid: pid}} ->
      send(pid, {:approval_response, ref, :denied})
    end)

    # Commit any in-progress streaming response so it isn't lost
    {new_messages, stop_broadcast} =
      case state.streaming_response do
        nil ->
          {state.messages, :stopped}

        resp
        when resp.content != "" or resp.reasoning_content != "" or resp.tool_calls != [] ->
          # Strip in-progress tool calls — they were never completed and must not be persisted
          if resp.content != "" or resp.reasoning_content != "" do
            partial_message = %{
              role: :assistant,
              content: resp.content,
              reasoning_content: resp.reasoning_content,
              tool_calls: [],
              interrupted: true
            }

            store_message(state.conversation_id, state.name, partial_message)
            {state.messages ++ [partial_message], {:stopped, partial_message}}
          else
            {state.messages, :stopped}
          end

        _ ->
          {state.messages, :stopped}
      end

    Conversation.set_stopped(state.name, true)
    broadcast_ui(state.name, stop_broadcast)
    broadcast_admin_status(state.name, :stopped)

    {:noreply,
     %{
       state
       | ai_task_pid: nil,
         streaming_response: nil,
         pending_tool_calls: [],
         pending_approvals: %{},
         messages: new_messages,
         stopped: true,
         current_status: :stopped
     }}
  end

  def handle_cast({:approval_decision, ref, decision}, state) do
    case ApprovalTracker.resolve(state.pending_approvals, ref) do
      {nil, _} ->
        {:noreply, state}

      {pid, new_approvals} ->
        send(pid, {:approval_response, ref, decision})
        new_status = if map_size(new_approvals) == 0, do: :awaiting_tools, else: :pending_approval
        broadcast_admin_status(state.name, new_status)
        {:noreply, %{state | pending_approvals: new_approvals, current_status: new_status}}
    end
  end

  def handle_info({:stream, _inner}, %{stopped: true} = state), do: {:noreply, state}
  def handle_info({:finalize_response, _}, %{stopped: true} = state), do: {:noreply, state}

  def handle_info(
        {:stream, msg},
        %{streaming_response: %{id: current_id}} = state
      )
      when is_tuple(msg) and tuple_size(msg) in [2, 3] and
             elem(msg, 0) in @ai_stream_events and elem(msg, 1) != current_id do
    Logger.warning(
      "Received #{elem(msg, 0)} for id #{inspect(elem(msg, 1))} but current streaming response is for id #{inspect(current_id)}"
    )

    {:noreply, state}
  end

  def handle_info({:stream, inner}, state) do
    with_status_broadcast(state, StreamHandler.handle(inner, state))
  end

  def handle_info({:error, inner}, state) do
    with_status_broadcast(state, ErrorHandler.handle(inner, state))
  end

  def handle_info({:finalize_response, _id} = msg, state) do
    with_status_broadcast(state, StreamHandler.handle(msg, state))
  end

  def handle_info({:register_pending_approval, ref, pid, command, reason}, state) do
    broadcast_admin_status(state.name, :pending_approval)

    {:noreply,
     %{
       state
       | current_status: :pending_approval,
         pending_approvals:
           ApprovalTracker.register(state.pending_approvals, ref, pid, command, reason)
     }}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: LiveviewSession.handle_down(ref, pid, reason, state)

  # MCP tools changed — rebuild mcp_tools for this conversation
  def handle_info({:mcp_tools_updated, _tools}, state) do
    mcp_tools = AiTools.build_mcp_tools(self(), state.allowed_tools)
    {:noreply, %{state | mcp_tools: mcp_tools}}
  end

  def handle_call({:conversation, inner}, from, state),
    do: ConversationCalls.handle_call(inner, from, state)

  def handle_call({:session, inner}, from, state),
    do: LiveviewSession.handle_call(inner, from, state)

  def handle_call({:tool_config, inner}, from, state),
    do: ToolConfig.handle_call(inner, from, state)

  defp with_status_broadcast(
         %{current_status: old, name: name},
         {:noreply, %{current_status: new} = new_state}
       )
       when old != new do
    broadcast_admin_status(name, new)
    {:noreply, new_state}
  end

  defp with_status_broadcast(_old_state, result), do: result

  defp broadcast_admin_status(name, status) do
    Phoenix.PubSub.broadcast(ElixirAi.PubSub, admin_topic(), {:runner_status, name, status})
  end
end
