defmodule ElixirAiWeb.NewProviderFormLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.AiProvider

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(
       :form_data,
       fn ->
         %{
           "name" => "",
           "model_name" => "",
           "api_token" => "",
           "completions_url" => "",
           "capabilities" => ["text"]
         }
       end
     )
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
          {if @show_form, do: "Cancel", else: "Add Provider"}
        </button>
      </div>

      <%= if @show_form do %>
        <form
          phx-submit="create_provider"
          phx-target={@myself}
          class="mb-8 space-y-2 p-4 rounded-lg border border-seafoam-900/40 bg-seafoam-950/10"
        >
          <.input type="text" name="name" value={@form_data["name"]} label="Provider Name" />
          <.input type="text" name="model_name" value={@form_data["model_name"]} label="Model Name" />
          <.input type="password" name="api_token" value={@form_data["api_token"]} label="API Token" />
          <.input
            type="text"
            name="completions_url"
            value={@form_data["completions_url"]}
            label="Completions URL"
          />
          <div class="pt-1">
            <label class="block text-xs font-medium text-seafoam-500 mb-1.5">Capabilities</label>
            <div class="flex gap-4">
              <%= for cap <- AiProvider.valid_capabilities() do %>
                <.toggle
                  id={"new-provider-cap-#{cap}"}
                  checked={cap in @form_data["capabilities"]}
                  label={cap}
                  phx-click="toggle_capability"
                  phx-value-capability={cap}
                  phx-target={@myself}
                />
              <% end %>
            </div>
          </div>
          <%= if @error do %>
            <p class="text-sm text-red-400">{@error}</p>
          <% end %>
          <button
            type="submit"
            class="w-full px-4 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
          >
            Create Provider
          </button>
        </form>
      <% end %>
    </div>
    """
  end

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, error: nil)}
  end

  def handle_event("toggle_capability", %{"capability" => capability}, socket) do
    current = socket.assigns.form_data["capabilities"] || []

    new_caps =
      if capability in current, do: List.delete(current, capability), else: [capability | current]

    {:noreply,
     assign(socket, form_data: Map.put(socket.assigns.form_data, "capabilities", new_caps))}
  end

  def handle_event("create_provider", params, socket) do
    name = String.trim(params["name"])
    model_name = String.trim(params["model_name"])
    api_token = String.trim(params["api_token"])
    completions_url = String.trim(params["completions_url"])

    cond do
      name == "" ->
        {:noreply, assign(socket, error: "Provider name can't be blank")}

      model_name == "" ->
        {:noreply, assign(socket, error: "Model name can't be blank")}

      api_token == "" ->
        {:noreply, assign(socket, error: "API token can't be blank")}

      completions_url == "" ->
        {:noreply, assign(socket, error: "Completions URL can't be blank")}

      true ->
        attrs = %{
          name: name,
          model_name: model_name,
          api_token: api_token,
          completions_url: completions_url,
          capabilities: socket.assigns.form_data["capabilities"] || ["text"]
        }

        case AiProvider.create(attrs) do
          :ok ->
            {:noreply,
             socket
             |> assign(show_form: false, error: nil)
             |> assign(
               form_data: %{
                 "name" => "",
                 "model_name" => "",
                 "api_token" => "",
                 "completions_url" => "",
                 "capabilities" => ["text"]
               }
             )}

          _ ->
            {:noreply, assign(socket, error: "Failed to create provider")}
        end
    end
  end
end
