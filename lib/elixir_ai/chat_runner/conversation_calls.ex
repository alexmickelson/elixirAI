defmodule ElixirAi.ChatRunner.ConversationCalls do
  import ElixirAi.ChatRunner.OutboundHelpers

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

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_streaming_response, _from, state) do
    {:reply, state.streaming_response, state}
  end
end
