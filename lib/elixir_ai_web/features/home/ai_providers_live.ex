defmodule ElixirAiWeb.AiProvidersLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.AiProvider

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:confirm_delete_id, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-lg font-semibold text-seafoam-300">AI Providers</h1>
        <.live_component module={ElixirAiWeb.NewProviderFormLive} id="new-provider-form" />
      </div>

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
                <p class="text-xs text-seafoam-700 mt-0.5">
                  Added: {Calendar.strftime(provider.inserted_at, "%b %d, %Y %H:%M:%S.%f")}
                </p>
                <div class="mt-2 flex gap-4">
                  <%= for cap <- AiProvider.valid_capabilities() do %>
                    <.toggle
                      id={"provider-#{provider.id}-cap-#{cap}"}
                      checked={cap in (provider.capabilities || [])}
                      label={cap}
                      phx-click="toggle_capability"
                      phx-value-id={provider.id}
                      phx-value-capability={cap}
                      phx-target={@myself}
                    />
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

  def handle_event("toggle_capability", %{"id" => id, "capability" => capability}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == id))
    current = (provider && provider.capabilities) || []

    new_caps =
      if capability in current, do: List.delete(current, capability), else: [capability | current]

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
end
