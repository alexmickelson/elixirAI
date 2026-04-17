defmodule ElixirAiWeb.ChatToolsLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.{AiTools, ChatRunner}

  def update(%{mcp_tools_updated: true} = assigns, socket) do
    all = AiTools.all_tool_names()
    grouped = group_tools(all)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(all_tools: all, tool_groups: grouped)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:all_tools, fn -> AiTools.all_tool_names() end)
     |> assign_new(:tool_groups, fn -> group_tools(AiTools.all_tool_names()) end)
     |> assign_new(:allowed_tools, fn ->
       case get_allowed_tools(assigns) do
         tools when is_list(tools) -> tools
         _ -> AiTools.all_tool_names()
       end
     end)}
  end

  def render(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_tools_popup"
        phx-target={@myself}
        class="px-3 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors flex items-center gap-1"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M11.42 15.17l-5.1 5.1a2.12 2.12 0 01-3-3l5.1-5.1m0 0L3.07 7.83a1.5 1.5 0 010-2.12l1.42-1.42a1.5 1.5 0 012.12 0l4.24 4.24m0 0l2.12-2.12m-2.12 2.12l5.1 5.1a2.12 2.12 0 003-3l-5.1-5.1m0 0l2.12-2.12a1.5 1.5 0 012.12 0l1.42 1.42a1.5 1.5 0 010 2.12L16.93 12"
          />
        </svg>
        Tools
      </button>

      <%= if @open do %>
        <div class="absolute bottom-full mb-2 right-0 w-72 max-h-96 overflow-y-auto rounded-lg border border-seafoam-900/40 bg-seafoam-950 shadow-lg z-50">
          <div class="px-3 py-2 border-b border-seafoam-900/40">
            <span class="text-sm font-medium text-seafoam-300">Toggle Tools</span>
          </div>
          <%= for {group_label, tools} <- @tool_groups do %>
            <div class="px-3 pt-2 pb-1">
              <span class="text-[10px] uppercase tracking-wider text-seafoam-600 font-medium">
                {group_label}
              </span>
            </div>
            <ul class="py-1">
              <%= for tool <- tools do %>
                <li class="px-3 py-1.5">
                  <.toggle
                    id={"chat-tool-#{tool}"}
                    checked={tool in @allowed_tools}
                    label={display_tool_name(tool)}
                    phx-click="toggle_tool"
                    phx-value-tool={tool}
                    phx-target={@myself}
                  />
                </li>
              <% end %>
            </ul>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("toggle_tools_popup", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open)}
  end

  def handle_event("toggle_tool", %{"tool" => tool_name}, socket) do
    allowed = socket.assigns.allowed_tools

    new_allowed =
      if tool_name in allowed do
        List.delete(allowed, tool_name)
      else
        allowed ++ [tool_name]
      end

    ChatRunner.set_allowed_tools(socket.assigns.conversation_name, new_allowed)
    {:noreply, assign(socket, allowed_tools: new_allowed)}
  end

  defp get_allowed_tools(%{runner_pid: pid}) when is_pid(pid) do
    case GenServer.call(pid, {:conversation, :get_conversation}) do
      %{allowed_tools: tools} -> tools
      _ -> nil
    end
  end

  defp get_allowed_tools(%{conversation_name: name}) do
    case ChatRunner.get_conversation(name) do
      %{allowed_tools: tools} -> tools
      _ -> nil
    end
  end

  defp get_allowed_tools(_), do: nil

  # Groups tool names into [{label, [tool_names]}] for sectioned display.
  # Built-in tools go under "Built-in", MCP tools grouped by server name.
  defp group_tools(all_tools) do
    {builtin, mcp} = Enum.split_with(all_tools, &(not String.starts_with?(&1, "mcp:")))

    mcp_groups =
      mcp
      |> Enum.group_by(fn name ->
        case String.split(name, ":", parts: 3) do
          ["mcp", server, _tool] -> server
          _ -> "mcp"
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {server, tools} -> {"MCP: #{server}", tools} end)

    [{"Built-in", builtin} | mcp_groups]
    |> Enum.reject(fn {_, tools} -> tools == [] end)
  end

  # Strips the "mcp:server:" prefix for cleaner display in the toggle list.
  defp display_tool_name(name) do
    case String.split(name, ":", parts: 3) do
      ["mcp", _server, tool_name] -> tool_name
      _ -> name
    end
  end
end
