defmodule ElixirAiWeb.HomeLive do
  use ElixirAiWeb, :live_view
  import ElixirAiWeb.FormComponents
  alias ElixirAi.{ConversationManager, AiProvider}
  require Logger

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirAi.PubSub, "ai_providers")
    end

    conversations = ConversationManager.list_conversations()

    Logger.debug(
      "Conversations: #{inspect(conversations, limit: :infinity, printable_limit: :infinity)}"
    )

    ai_providers = AiProvider.all()

    Logger.debug(
      "AI Providers: #{inspect(ai_providers, limit: :infinity, printable_limit: :infinity)}"
    )

    {:ok,
     socket
     |> assign(conversations: conversations)
     |> assign(ai_providers: ai_providers)
     |> assign(new_name: "")
     |> assign(error: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto mt-16 px-4 space-y-16">
      <div>
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

        <form phx-submit="create" class="space-y-2">
          <.input type="text" name="name" value={@new_name} label="Conversation Name" />
          <select
            name="ai_provider_id"
            class="w-full rounded px-3 py-2 text-sm bg-cyan-950/20 border border-cyan-900/40 text-cyan-100 focus:outline-none focus:ring-1 focus:ring-cyan-700"
          >
            <option value="">Select AI Provider</option>
            <%= for provider <- @ai_providers do %>
              <option value={provider.id}>{provider.name} - {provider.model_name}</option>
            <% end %>
          </select>
          <button
            type="submit"
            class="w-full px-4 py-2 rounded text-sm border border-cyan-900/40 bg-cyan-950/20 text-cyan-300 hover:border-cyan-700 hover:bg-cyan-950/40 transition-colors"
          >
            Create
          </button>
        </form>

        <%= if @error do %>
          <p class="mt-2 text-sm text-red-400">{@error}</p>
        <% end %>
      </div>

      <%!-- <div>
        <.live_component module={ElixirAiWeb.AiProvidersLive} id="ai-providers" />
      </div> --%>
    </div>
    """
  end

  def handle_event("create", %{"name" => name, "ai_provider_id" => provider_id}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, assign(socket, error: "Name can't be blank")}

      provider_id == "" ->
        {:noreply, assign(socket, error: "Please select an AI provider")}

      true ->
        case ConversationManager.create_conversation(name, provider_id) do
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

  def handle_info({:provider_added, _attrs}, socket) do
    {:noreply, assign(socket, ai_providers: AiProvider.all())}
  end
end
