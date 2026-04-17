defmodule ElixirAiWeb.McpServersLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.McpServer
  alias ElixirAi.Mcp.McpServerManager

  def update(%{test_complete: {name, result}} = _assigns, socket) do
    {:ok,
     socket
     |> assign(
       testing: MapSet.delete(socket.assigns.testing, name),
       test_results: Map.put(socket.assigns.test_results, name, result)
     )
     |> assign_statuses()}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:confirm_delete_name, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:testing, fn -> MapSet.new() end)
     |> assign_new(:test_results, fn -> %{} end)
     |> assign_new(:expanded, fn -> MapSet.new() end)
     |> assign_statuses()
     |> assign_server_tools()}
  end

  defp assign_statuses(socket) do
    statuses =
      Map.new(socket.assigns.mcp_servers, fn server ->
        {server.name, McpServerManager.server_status(server.name)}
      end)

    assign(socket, :statuses, statuses)
  end

  defp assign_server_tools(socket) do
    mcp_tools =
      try do
        McpServerManager.list_mcp_tools()
      catch
        _, _ -> []
      end

    tools_by_server = Map.new(mcp_tools, fn {name, tools} -> {name, tools} end)
    assign(socket, :server_tools, tools_by_server)
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-lg font-semibold text-seafoam-300">MCP Servers</h1>
        <.live_component module={ElixirAiWeb.NewMcpServerFormLive} id="new-mcp-server-form" />
      </div>

      <%= if @error do %>
        <p class="mb-4 text-sm text-red-400">{@error}</p>
      <% end %>

      <ul class="space-y-2">
        <%= if @mcp_servers == [] do %>
          <li class="text-sm text-seafoam-700">No MCP servers configured yet.</li>
        <% end %>
        <%= for server <- @mcp_servers do %>
          <li class="p-4 rounded-lg border border-seafoam-900/40 bg-seafoam-950/20">
            <div class="flex items-start justify-between gap-4">
              <div class="flex flex-col gap-3 flex-1 min-w-0">
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="text-sm font-medium text-seafoam-300">{server.name}</h3>
                    <span class={[
                      "inline-block w-2 h-2 rounded-full",
                      status_color(@statuses[server.name])
                    ]} />
                    <span class="text-xs text-seafoam-600">
                      {status_label(@statuses[server.name])}
                    </span>
                  </div>
                  <p class="text-xs text-seafoam-500 mt-1">{server.url}</p>
                  <p class="text-xs text-seafoam-700 mt-0.5">
                    Added: {Calendar.strftime(server.inserted_at, "%b %d, %Y %H:%M:%S")}
                  </p>
                </div>

                <div class="flex items-center gap-2">
                  <button
                    phx-click="test_connection"
                    phx-value-name={server.name}
                    phx-target={@myself}
                    disabled={MapSet.member?(@testing, server.name)}
                    class={[
                      "px-2 py-1 rounded text-xs border transition-colors",
                      if(MapSet.member?(@testing, server.name),
                        do: "border-seafoam-900/20 bg-seafoam-950/10 text-seafoam-600 cursor-wait",
                        else:
                          "border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40"
                      )
                    ]}
                  >
                    {if MapSet.member?(@testing, server.name), do: "Testing…", else: "Test Connection"}
                  </button>
                  <button
                    phx-click="toggle_tools"
                    phx-value-name={server.name}
                    phx-target={@myself}
                    class="px-2 py-1 rounded text-xs border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
                  >
                    {if MapSet.member?(@expanded, server.name), do: "Hide Tools", else: "Show Tools"}
                    <span class="text-seafoam-600 ml-1">
                      ({length(Map.get(@server_tools, server.name, []))})
                    </span>
                  </button>
                  <button
                    phx-click="delete_server"
                    phx-value-name={server.name}
                    phx-target={@myself}
                    class="px-2 py-1 rounded text-xs border border-red-900/40 bg-red-950/20 text-red-400 hover:border-red-700 hover:bg-red-950/40 transition-colors"
                  >
                    Delete
                  </button>
                </div>

                <%= if test_result = @test_results[server.name] do %>
                  <p class={[
                    "text-xs",
                    if(elem(test_result, 0) == :ok, do: "text-green-400", else: "text-red-400")
                  ]}>
                    {format_test_result(test_result)}
                  </p>
                <% end %>

                <%= if MapSet.member?(@expanded, server.name) do %>
                  <div class="mt-1 pl-2 border-l border-seafoam-900/30">
                    <%= case Map.get(@server_tools, server.name, []) do %>
                      <% [] -> %>
                        <p class="text-xs text-seafoam-700">No tools discovered.</p>
                      <% tools -> %>
                        <ul class="space-y-1">
                          <%= for tool <- tools do %>
                            <li class="text-xs">
                              <span class="text-seafoam-300 font-medium">{tool["name"]}</span>
                              <%= if tool["description"] do %>
                                <span class="text-seafoam-600 ml-1.5">{tool["description"]}</span>
                              <% end %>
                            </li>
                          <% end %>
                        </ul>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="shrink-0">
                <.toggle
                  id={"mcp-server-#{server.name}-enabled"}
                  checked={server.enabled}
                  label="Enabled"
                  phx-click="toggle_enabled"
                  phx-value-name={server.name}
                  phx-target={@myself}
                />
              </div>
            </div>
          </li>
        <% end %>
      </ul>

      <%= if @confirm_delete_name do %>
        <.modal>
          <h2 class="text-sm font-semibold text-seafoam-300 mb-2">Delete MCP Server</h2>
          <p class="text-sm text-seafoam-500 mb-6">
            Are you sure you want to delete <strong class="text-seafoam-300">{@confirm_delete_name}</strong>? This action cannot be undone.
          </p>
          <div class="flex gap-3 justify-end">
            <button
              phx-click="cancel_delete"
              phx-target={@myself}
              class="px-4 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
            >
              Cancel
            </button>
            <button
              phx-click="confirm_delete"
              phx-target={@myself}
              class="px-4 py-2 rounded text-sm border border-red-900/40 bg-red-950/20 text-red-400 hover:border-red-700 hover:bg-red-950/40 transition-colors"
            >
              Delete
            </button>
          </div>
        </.modal>
      <% end %>
    </div>
    """
  end

  def handle_event("toggle_enabled", %{"name" => name}, socket) do
    server = Enum.find(socket.assigns.mcp_servers, &(&1.name == name))

    case McpServer.update_enabled(name, !server.enabled) do
      :ok -> {:noreply, socket}
      _ -> {:noreply, assign(socket, error: "Failed to update server")}
    end
  end

  def handle_event("test_connection", %{"name" => name}, socket) do
    server = Enum.find(socket.assigns.mcp_servers, &(&1.name == name))

    if server do
      testing = MapSet.put(socket.assigns.testing, name)
      test_results = Map.delete(socket.assigns.test_results, name)
      parent = self()

      Task.start(fn ->
        result = McpServerManager.test_connection(name, server.url, server.headers)
        send_update(parent, __MODULE__, id: "mcp-servers", test_complete: {name, result})
      end)

      {:noreply, assign(socket, testing: testing, test_results: test_results)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_tools", %{"name" => name}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, name),
        do: MapSet.delete(socket.assigns.expanded, name),
        else: MapSet.put(socket.assigns.expanded, name)

    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("delete_server", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_delete_name: name)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_name: nil)}
  end

  def handle_event("confirm_delete", _params, socket) do
    name = socket.assigns.confirm_delete_name

    case McpServer.delete(name) do
      :ok ->
        McpServerManager.remove_server(name)
        {:noreply, assign(socket, confirm_delete_name: nil)}

      _ ->
        {:noreply, assign(socket, confirm_delete_name: nil, error: "Failed to delete server")}
    end
  end

  defp status_color(:connected), do: "bg-green-400"
  defp status_color(_), do: "bg-seafoam-700"

  defp status_label(:connected), do: "connected"
  defp status_label(_), do: "disconnected"

  defp format_test_result({:ok, count}), do: "✓ Connected — #{count} tool(s) available"
  defp format_test_result({:error, reason}), do: "✗ #{reason}"
end
