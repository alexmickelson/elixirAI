defmodule ElixirAi.ChatRunner.ConversationCalls do
  import ElixirAi.ChatRunner.OutboundHelpers
  import ElixirAi.PubsubTopics
  alias ElixirAi.Message

  def handle_cast(:ai_turn, state) do
    state = drop_interrupted_reasoning_message(state)
    new_state = %{state | current_status: :generating_ai_response}

    {:ok, task_pid} =
      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(new_state.messages, state.system_prompt),
        state.server_tools ++ state.liveview_tools ++ state.page_tools,
        state.provider,
        state.tool_choice,
        state.response_format
      )

    {:noreply, %{new_state | ai_task_pid: task_pid}}
  end

  def handle_cast({:user_message, text_content, tool_choice_override}, state) do
    effective_tool_choice = tool_choice_override || state.tool_choice
    new_message = %{role: :user, content: text_content, tool_choice: tool_choice_override}
    store_message(state.conversation_id, state.name, new_message)
    broadcast_ui(state.name, {:user_chat_message, new_message})

    new_state = %{
      state
      | messages: state.messages ++ [new_message],
        current_status: :generating_ai_response
    }

    {:ok, task_pid} =
      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(new_state.messages, state.system_prompt),
        state.server_tools ++ state.liveview_tools ++ state.page_tools,
        state.provider,
        effective_tool_choice,
        state.response_format
      )

    {:noreply, %{new_state | ai_task_pid: task_pid}}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_streaming_response, _from, state) do
    {:reply, state.streaming_response, state}
  end

  # If the last message is an interrupted assistant message with only reasoning_content
  # (no actual text content), it means the user stopped mid-reasoning. Such a message
  # cannot be sent as an assistant prefill — it causes "incompatible with enable thinking"
  # errors. Delete it from the database first, then remove it from state and notify
  # the frontend to drop it.
  defp drop_interrupted_reasoning_message(%{messages: messages} = state) do
    case List.last(messages) do
      %{role: :assistant, reasoning_content: reasoning, content: content, interrupted: true}
      when is_binary(reasoning) and reasoning != "" and
             (is_nil(content) or content == "") ->
        topic = conversation_message_topic(state.name)
        Message.delete_last_reasoning_only_message(state.conversation_id, topic: topic)
        broadcast_ui(state.name, :remove_last_message)
        %{state | messages: List.delete_at(messages, -1)}

      _ ->
        state
    end
  end
end
