defmodule ElixirAiWeb.AiProvidersLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.AiProvider

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(:confirm_delete_id, fn -> nil end)
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
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-lg font-semibold text-seafoam-300">AI Providers</h1>
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
                <button
                  type="button"
                  phx-click="toggle_new_capability"
                  phx-value-capability={cap}
                  phx-target={@myself}
                  class="flex items-center gap-1.5 cursor-pointer group"
                >
                  <span class="text-xs text-seafoam-500 group-hover:text-seafoam-300 transition-colors capitalize">
                    {cap}
                  </span>
                  <span class={[
                    "relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
                    if(cap in @form_data["capabilities"],
                      do: "bg-seafoam-500",
                      else: "bg-seafoam-900/60"
                    )
                  ]}>
                    <span class={[
                      "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow ring-0 transition-transform duration-200 ease-in-out",
                      if(cap in @form_data["capabilities"],
                        do: "translate-x-4",
                        else: "translate-x-0"
                      )
                    ]} />
                  </span>
                </button>
              <% end %>
            </div>
          </div>
          <button
            type="submit"
            class="w-full px-4 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
          >
            Create Provider
          </button>
        </form>
      <% end %>

      <%= if @error do %>
        <p class="mb-4 text-sm text-red-400">{@error}</p>
      <% end %>

      <ul class="space-y-2">
        <%= if @providers == [] do %>
          <li class="text-sm text-seafoam-700">No providers configured yet.</li>
        <% end %>
        <%= for provider <- @providers do %>
          <li class="p-4 rounded-lg border border-seafoam-900/40 bg-seafoam-950/20">
            <div class="flex items-start justify-between">
              <div class="flex-1">
                <h3 class="text-sm font-medium text-seafoam-300">{provider.name}</h3>
                <p class="text-xs text-seafoam-500 mt-1">Model: {provider.model_name}</p>
                <div class="mt-2 flex gap-4">
                  <%= for cap <- AiProvider.valid_capabilities() do %>
                    <button
                      type="button"
                      phx-click="toggle_capability"
                      phx-value-id={provider.id}
                      phx-value-capability={cap}
                      phx-target={@myself}
                      class="flex items-center gap-1.5 cursor-pointer group"
                    >
                      <span class="text-xs text-seafoam-500 group-hover:text-seafoam-300 transition-colors capitalize">
                        {cap}
                      </span>
                      <span class={[
                        "relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
                        if(cap in (provider.capabilities || []),
                          do: "bg-seafoam-500",
                          else: "bg-seafoam-900/60"
                        )
                      ]}>
                        <span class={[
                          "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow ring-0 transition-transform duration-200 ease-in-out",
                          if(cap in (provider.capabilities || []),
                            do: "translate-x-4",
                            else: "translate-x-0"
                          )
                        ]} />
                      </span>
                    </button>
                  <% end %>
                </div>
              </div>
              <button
                phx-click="delete_provider"
                phx-value-id={provider.id}
                phx-target={@myself}
                class="ml-4 px-2 py-1 rounded text-xs border border-red-900/40 bg-red-950/20 text-red-400 hover:border-red-700 hover:bg-red-950/40 transition-colors"
              >
                Delete
              </button>
            </div>
          </li>
        <% end %>
      </ul>

      <%= if @confirm_delete_id do %>
        <.modal>
          <h2 class="text-sm font-semibold text-seafoam-300 mb-2">Delete Provider</h2>
          <p class="text-sm text-seafoam-500 mb-6">
            Are you sure you want to delete this provider? This action cannot be undone.
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

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, error: nil)}
  end

  def handle_event("toggle_new_capability", %{"capability" => capability}, socket) do
    current = socket.assigns.form_data["capabilities"] || []

    new_caps =
      if capability in current,
        do: List.delete(current, capability),
        else: [capability | current]

    {:noreply,
     assign(socket, form_data: Map.put(socket.assigns.form_data, "capabilities", new_caps))}
  end

  def handle_event("toggle_capability", %{"id" => id, "capability" => capability}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == id))
    current = (provider && provider.capabilities) || []

    new_caps =
      if capability in current,
        do: List.delete(current, capability),
        else: [capability | current]

    case AiProvider.update_capabilities(id, new_caps) do
      :ok -> {:noreply, socket}
      _ -> {:noreply, assign(socket, error: "Failed to update capabilities")}
    end
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  def handle_event("confirm_delete", _params, socket) do
    case AiProvider.delete(socket.assigns.confirm_delete_id) do
      :ok ->
        {:noreply, assign(socket, confirm_delete_id: nil)}

      _ ->
        {:noreply, assign(socket, confirm_delete_id: nil, error: "Failed to delete provider")}
    end
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
             |> assign(show_form: false)
             |> assign(
               form_data: %{
                 "name" => "",
                 "model_name" => "",
                 "api_token" => "",
                 "completions_url" => "",
                 "capabilities" => ["text"]
               }
             )
             |> assign(error: nil)}

          _ ->
            {:noreply, assign(socket, error: "Failed to create provider")}
        end
    end
  end
end
