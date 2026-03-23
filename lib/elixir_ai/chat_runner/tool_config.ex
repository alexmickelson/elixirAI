defmodule ElixirAi.ChatRunner.ToolConfig do
  alias ElixirAi.{AiTools, Conversation}

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
end
