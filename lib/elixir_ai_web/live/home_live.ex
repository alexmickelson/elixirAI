defmodule ElixirAiWeb.HomeLive do
  use ElixirAiWeb, :live_view
  alias ElixirAi.ConversationManager

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(conversations: ConversationManager.list_conversations())
     |> assign(new_name: "")
     |> assign(error: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto mt-16 px-4">
      <h1 class="text-lg font-semibold text-cyan-300 mb-8">Conversations</h1>

      <ul class="mb-8 space-y-2">
        <%= if @conversations == [] do %>
          <li class="text-sm text-cyan-700">No conversations yet.</li>
        <% end %>
        <%= for name <- @conversations do %>
          <li>
            <.link
              navigate={~p"/chat/#{name}"}
              class="block px-4 py-2 rounded-lg border border-cyan-900/40 bg-cyan-950/20 text-cyan-300 hover:border-cyan-700 hover:bg-cyan-950/40 transition-colors text-sm"
            >
              {name}
            </.link>
          </li>
        <% end %>
      </ul>

      <form phx-submit="create" class="flex gap-2">
        <input
          type="text"
          name="name"
          value={@new_name}
          placeholder="New conversation name"
          class="flex-1 rounded px-3 py-2 text-sm bg-cyan-950/20 border border-cyan-900/40 text-cyan-100 placeholder-cyan-800 focus:outline-none focus:ring-1 focus:ring-cyan-700"
          autocomplete="off"
        />
        <button
          type="submit"
          class="px-4 py-2 rounded text-sm border border-cyan-900/40 bg-cyan-950/20 text-cyan-300 hover:border-cyan-700 hover:bg-cyan-950/40 transition-colors"
        >
          Create
        </button>
      </form>

      <%= if @error do %>
        <p class="mt-2 text-sm text-red-400">{@error}</p>
      <% end %>
    </div>
    """
  end

  @spec handle_event(<<_::48>>, map(), any()) :: {:noreply, any()}
  def handle_event("create", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, error: "Name can't be blank")}
    else
      case ConversationManager.create_conversation(name) do
        {:ok, _pid} ->
          {:noreply,
           socket
           |> push_navigate(to: ~p"/chat/#{name}")
           |> assign(error: nil)}

        {:error, :already_exists} ->
          {:noreply, assign(socket, error: "A conversation with that name already exists")}

        _ ->
          {:noreply, assign(socket, error: "Failed to create conversation")}
      end
    end
  end
end
