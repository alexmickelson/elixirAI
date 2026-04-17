defmodule ElixirAi.ChatRunner.ConversationCalls do
  import ElixirAi.ChatRunner.OutboundHelpers

  def handle_cast(:ai_turn, state) do
    new_state = %{state | current_status: :generating_ai_response}

    {:ok, task_pid} =
      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(new_state.messages, state.system_prompt),
        state.server_tools ++ state.liveview_tools ++ state.page_tools ++ state.mcp_tools,
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
        state.server_tools ++ state.liveview_tools ++ state.page_tools ++ state.mcp_tools,
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
end
