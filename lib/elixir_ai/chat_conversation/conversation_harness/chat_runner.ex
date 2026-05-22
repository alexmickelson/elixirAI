defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  alias ElixirAi.{AiTools, Conversation, Message}
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

    # pending_approvals are data only — no task pids to notify.
    # The tool call cycle is stripped below, so no tool_response needed.

    topic = conversation_message_topic(state.name)

    # Discard any in-progress streaming response without persisting it.
    # Storing a partial assistant message leaves the conversation in an invalid
    # state where the last message is an assistant turn, which causes providers
    # to reject the next AI request ("Cannot have 2+ assistant messages at end").
    # If there was streaming content in the UI, clearing streaming_response
    # causes the streaming bubble to unmount on the next render.

    # Clean up any dangling tool call cycle if stop was pressed while tools
    # were running. The assistant message with tool_calls was already stored,
    # but with no (or incomplete) tool responses it cannot be used in future
    # API requests.
    {cleaned_messages, tool_cycle_removed_count} =
      if state.pending_tool_calls != [] do
        strip_tool_cycle_after_interupt(state.messages)
      else
        {state.messages, 0}
      end

    if tool_cycle_removed_count > 0 do
      Message.delete_interrupted_tool_cycle(state.conversation_id, topic: topic)

      Enum.each(1..tool_cycle_removed_count, fn _ ->
        broadcast_ui(state.name, :remove_last_message)
      end)
    end

    Conversation.set_stopped(state.name, true)
    broadcast_ui(state.name, :stopped)
    broadcast_admin_status(state.name, :stopped)

    {:noreply,
     %{
       state
       | ai_task_pid: nil,
         streaming_response: nil,
         pending_tool_calls: [],
         pending_approvals: %{},
         messages: cleaned_messages,
         stopped: true,
         current_status: :stopped
     }}
  end

  def handle_cast({:approval_decision, ref, decision}, state) do
    case ApprovalTracker.resolve(state.pending_approvals, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{current_message_id: mid, tool_call_id: tcid, command: cmd, reason: reason}, new_approvals} ->
        topic = conversation_message_topic(state.name)

        case decision do
          :approved -> execute_approved_tool(state, new_approvals, mid, tcid, cmd, reason, topic)
          {:denied, user_reason} -> deny_tool_with_user_reason(state, new_approvals, mid, tcid, cmd, reason, user_reason, topic)
          :denied -> deny_tool_silently(state, new_approvals, mid, tcid, cmd, reason, topic)
        end
    end
  end

  defp execute_approved_tool(state, new_approvals, mid, tcid, cmd, reason, topic) do
    Message.update_approval_decision(tcid, "approved", justification: reason, topic: topic)
    broadcast_ui(state.name, {:tool_approval_updated, tcid, "approved", reason})
    AiTools.execute_approved_run(self(), mid, tcid, cmd)

    new_status = if map_size(new_approvals) == 0, do: :awaiting_tools, else: :pending_approval
    broadcast_admin_status(state.name, new_status)
    {:noreply, %{state | pending_approvals: new_approvals, current_status: new_status}}
  end

  defp deny_tool_with_user_reason(state, new_approvals, _mid, tcid, cmd, reason, user_reason, topic) do
    justification = "#{reason}\nUser reason: #{user_reason}"
    denial_content = "[denied] User declined: #{cmd}\nUser reason: #{user_reason}\n[exit:1 | 0ms]"

    Message.update_approval_decision(tcid, "denied", justification: justification, topic: topic)

    # Write tool response to DB first (critical path) so recovery can reconstruct
    # the conversation and the LLM sees a completed tool call rather than a dangling one.
    tool_response_msg = %{
      role: :tool,
      content: inspect({:ok, denial_content}, printable_limit: :infinity),
      tool_call_id: tcid
    }

    store_message(state.conversation_id, state.name, tool_response_msg)
    broadcast_ui(state.name, {:tool_approval_updated, tcid, "denied", justification})
    broadcast_ui(state.name, {:one_tool_finished, tool_response_msg})

    # Inject the user's reason as a user message so the LLM gets human context
    # and won't retry the same command blindly.
    user_msg = %{role: :user, content: user_reason}
    store_message(state.conversation_id, state.name, user_msg)
    broadcast_ui(state.name, {:user_chat_message, user_msg})

    new_pending = Enum.filter(state.pending_tool_calls, &(&1 != tcid))
    new_messages = state.messages ++ [tool_response_msg, user_msg]

    advance_after_tool_response(state, new_approvals, new_messages, new_pending)
  end

  defp deny_tool_silently(state, new_approvals, mid, tcid, cmd, reason, topic) do
    Message.update_approval_decision(tcid, "denied", justification: reason, topic: topic)
    broadcast_ui(state.name, {:tool_approval_updated, tcid, "denied", reason})

    send(self(), {:stream, {:tool_response, mid, tcid, {:ok, "[denied] User declined: #{cmd}\n[exit:1 | 0ms]"}}})

    new_status = if map_size(new_approvals) == 0, do: :awaiting_tools, else: :pending_approval
    broadcast_admin_status(state.name, new_status)
    {:noreply, %{state | pending_approvals: new_approvals, current_status: new_status}}
  end

  defp advance_after_tool_response(state, new_approvals, new_messages, new_pending) do
    if new_pending == [] do
      broadcast_ui(state.name, :tool_calls_finished)

      {:ok, task_pid} =
        ElixirAi.ChatUtils.request_ai_response(
          self(),
          messages_with_system_prompt(new_messages, state.system_prompt),
          state.server_tools ++ state.liveview_tools ++ state.page_tools,
          state.provider,
          state.tool_choice,
          state.response_format
        )

      new_status = if map_size(new_approvals) == 0, do: :generating_ai_response, else: :pending_approval
      broadcast_admin_status(state.name, new_status)

      {:noreply,
       %{
         state
         | messages: new_messages,
           pending_tool_calls: [],
           pending_approvals: new_approvals,
           ai_task_pid: task_pid,
           current_status: new_status
       }}
    else
      new_status = if map_size(new_approvals) == 0, do: :awaiting_tools, else: :pending_approval
      broadcast_admin_status(state.name, new_status)

      {:noreply,
       %{
         state
         | messages: new_messages,
           pending_tool_calls: new_pending,
           pending_approvals: new_approvals,
           current_status: new_status
       }}
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

  def handle_info({:pending_approval, ref, current_message_id, tool_call_id, command, reason}, state) do
    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      chat_topic(state.name),
      {:tool_approval_request, ref, command, reason}
    )

    broadcast_admin_status(state.name, :pending_approval)

    {:noreply,
     %{
       state
       | current_status: :pending_approval,
         pending_approvals:
           ApprovalTracker.register(
             state.pending_approvals,
             ref,
             current_message_id,
             tool_call_id,
             command,
             reason
           )
     }}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: LiveviewSession.handle_down(ref, pid, reason, state)

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

  # Finds the last assistant message with tool_calls in the message list and
  # removes it along with all subsequent tool-response messages (which belong to
  # that same tool-call cycle). Returns {cleaned_messages, count_removed}.
  defp strip_tool_cycle_after_interupt(messages) do
    last_tool_call_index =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _idx} ->
        msg.role == :assistant and
          is_list(Map.get(msg, :tool_calls)) and
          Map.get(msg, :tool_calls) != []
      end)
      |> List.last()
      |> case do
        nil -> nil
        {_msg, idx} -> idx
      end

    case last_tool_call_index do
      nil ->
        {messages, 0}

      idx ->
        cleaned = Enum.take(messages, idx)
        removed = length(messages) - idx
        {cleaned, removed}
    end
  end
end
