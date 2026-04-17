defmodule ElixirAiWeb.NewMcpServerFormLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.McpServer
  alias ElixirAi.Mcp.McpServerManager

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(:form_data, fn -> %{"name" => "", "url" => "", "headers" => ""} end)
     |> assign_new(:error, fn -> nil end)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="flex justify-end mb-8">
        <button
          phx-click="toggle_form"
          phx-target={@myself}
          class="px-3 py-1 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
        >
          {if @show_form, do: "Cancel", else: "Add Server"}
        </button>
      </div>

      <%= if @show_form do %>
        <form
          phx-submit="create_server"
          phx-target={@myself}
          class="mb-8 space-y-2 p-4 rounded-lg border border-seafoam-900/40 bg-seafoam-950/10"
        >
          <.input type="text" name="name" value={@form_data["name"]} label="Server Name" />
          <.input type="text" name="url" value={@form_data["url"]} label="URL" />
          <.input
            type="text"
            name="headers"
            value={@form_data["headers"]}
            label="Headers (JSON, optional)"
          />
          <%= if @error do %>
            <p class="text-sm text-red-400">{@error}</p>
          <% end %>
          <button
            type="submit"
            class="w-full px-4 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
          >
            Create Server
          </button>
        </form>
      <% end %>
    </div>
    """
  end

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, error: nil)}
  end

  def handle_event("create_server", params, socket) do
    name = String.trim(params["name"])
    url = String.trim(params["url"])
    raw_headers = String.trim(params["headers"] || "")

    cond do
      name == "" ->
        {:noreply, assign(socket, error: "Server name can't be blank")}

      url == "" ->
        {:noreply, assign(socket, error: "URL can't be blank")}

      true ->
        headers =
          if raw_headers == "" do
            %{}
          else
            case Jason.decode(raw_headers) do
              {:ok, map} when is_map(map) -> map
              _ -> :invalid
            end
          end

        if headers == :invalid do
          {:noreply, assign(socket, error: "Headers must be valid JSON object")}
        else
          attrs = %{name: name, url: url, headers: headers}

          case McpServer.create(attrs) do
            :ok ->
              McpServerManager.add_server(name, url, headers)

              {:noreply,
               socket
               |> assign(show_form: false, error: nil)
               |> assign(form_data: %{"name" => "", "url" => "", "headers" => ""})}

            _ ->
              {:noreply, assign(socket, error: "Failed to create server")}
          end
        end
    end
  end
end
