defmodule ElixirAi.ChatRunner.ToolConfig do
  alias ElixirAi.{AiProvider, AiTools, Conversation}

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

  def handle_call({:set_provider, provider_id}, _from, state) do
    with :ok <- Conversation.update_provider(state.name, provider_id),
         {:ok, provider} <- AiProvider.find_by_id(provider_id) do
      {:reply, {:ok, provider}, %{state | provider: provider}}
    else
      error -> {:reply, error, state}
    end
  end
end
