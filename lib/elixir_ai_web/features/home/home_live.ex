defmodule ElixirAiWeb.HomeLive do
  use ElixirAiWeb, :live_view
  import ElixirAiWeb.FormComponents
  alias ElixirAi.{ConversationManager, AiProvider}
  require Logger
  import ElixirAi.PubsubTopics

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirAi.PubSub, providers_topic())
      Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversations_topic())
      :pg.join(ElixirAi.LiveViewPG, {:liveview, __MODULE__}, self())
      send(self(), :load_data)
    end

    {:ok,
     socket
     |> assign(conversations: [])
     |> assign(ai_providers: [])
     |> assign(new_name: "")
     |> assign(confirm_delete_name: nil)
     |> assign(error: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto mt-16 px-4 space-y-16">
      <div>
        <h1 class="text-lg font-semibold text-seafoam-300 mb-8">Conversations</h1>

        <.conversation_list conversations={@conversations} confirm_delete_name={@confirm_delete_name} />

        <.create_conversation_form new_name={@new_name} ai_providers={@ai_providers} />

        <%= if @error do %>
          <p class="mt-2 text-sm text-red-400">{@error}</p>
        <% end %>
      </div>

      <div>
        <.live_component
          module={ElixirAiWeb.AiProvidersLive}
          id="ai-providers"
          providers={@ai_providers}
        />
      </div>
    </div>
    """
  end

  defp conversation_list(assigns) do
    ~H"""
    <ul class="mb-8 space-y-2">
      <%= if @conversations == [] do %>
        <li class="text-sm text-seafoam-700">No conversations yet.</li>
      <% end %>
      <%= for name <- @conversations do %>
        <li class="flex items-center rounded-lg border border-seafoam-900/40 bg-seafoam-950/20 overflow-hidden">
          <%= if @confirm_delete_name == name do %>
            <span class="flex-1 px-4 py-2 text-seafoam-500 text-sm">
              Delete <strong class="text-seafoam-300">{name}</strong>?
            </span>
            <button
              type="button"
              phx-click="cancel_delete_conversation"
              class="px-3 py-2 text-seafoam-500 hover:text-seafoam-300 hover:bg-seafoam-950/60 transition-colors text-xs border-l border-seafoam-900/40"
            >
              don't delete
            </button>
            <button
              type="button"
              phx-click="confirm_delete_conversation"
              class="flex items-center gap-1.5 px-3 py-2 text-red-300 bg-red-950/50 hover:text-red-100 hover:bg-red-900/50 transition-colors text-xs border-l border-red-500/80"
            >
              yes, delete
            </button>
          <% else %>
            <.link
              navigate={~p"/chat/#{name}"}
              class="flex-1 px-4 py-2 text-seafoam-300 hover:bg-seafoam-950/60 transition-colors text-sm"
            >
              {name}
            </.link>
            <button
              type="button"
              phx-click="delete_conversation"
              phx-value-name={name}
              class="flex items-center gap-1.5 px-3 py-2 text-red-300 bg-red-950/50 hover:text-red-100 hover:bg-red-900/50 transition-colors text-xs border-l border-red-500/80"
              title="Delete conversation"
            >
              delete
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-3.5 h-3.5"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M9 2a1 1 0 00-.894.553L7.382 4H4a1 1 0 000 2v10a2 2 0 002 2h8a2 2 0 002-2V6a1 1 0 100-2h-3.382l-.724-1.447A1 1 0 0011 2H9zM7 8a1 1 0 012 0v6a1 1 0 11-2 0V8zm5-1a1 1 0 00-1 1v6a1 1 0 102 0V8a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
            </button>
          <% end %>
        </li>
      <% end %>
    </ul>
    """
  end

  defp create_conversation_form(assigns) do
    ~H"""
    <form phx-submit="create" class="space-y-2">
      <.input type="text" name="name" value={@new_name} label="Conversation Name" />
      <select
        name="ai_provider_id"
        class="w-full rounded px-3 py-2 text-sm bg-seafoam-950/20 border border-seafoam-900/40 text-seafoam-100 focus:outline-none focus:ring-1 focus:ring-seafoam-700"
      >
        <%= for {provider, index} <- Enum.with_index(@ai_providers) do %>
          <option value={provider.id} selected={index == 0}>
            {provider.name} - {provider.model_name}
          </option>
        <% end %>
      </select>
      <button
        type="submit"
        class="w-full px-4 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors"
      >
        Create
      </button>
    </form>
    """
  end

  def handle_event("delete_conversation", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_delete_name: name)}
  end

  def handle_event("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, confirm_delete_name: nil)}
  end

  def handle_event("confirm_delete_conversation", _params, socket) do
    name = socket.assigns.confirm_delete_name

    case ConversationManager.delete_conversation(name) do
      :ok ->
        {:noreply, assign(socket, confirm_delete_name: nil)}

      {:error, _} ->
        {:noreply,
         assign(socket, confirm_delete_name: nil, error: "Failed to delete conversation")}
    end
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

          {:error, :failed_to_load} ->
            {:noreply,
             assign(socket,
               error: "Conversation was saved but failed to load"
             )}

          _ ->
            {:noreply, assign(socket, error: "Failed to create conversation")}
        end
    end
  end

  def handle_info(:load_data, socket) do
    conversations =
      case ConversationManager.list_conversations() do
        {:error, _} -> []
        list -> list
      end

    Logger.debug(
      "Conversations: #{inspect(conversations, limit: :infinity, printable_limit: :infinity)}"
    )

    ai_providers = AiProvider.all()

    Logger.debug(
      "AI Providers: #{inspect(ai_providers, limit: :infinity, printable_limit: :infinity)}"
    )

    {:noreply,
     socket
     |> assign(conversations: conversations)
     |> assign(ai_providers: ai_providers)}
  end

  def handle_info({:provider_added, _attrs}, socket) do
    {:noreply, assign(socket, ai_providers: AiProvider.all())}
  end

  def handle_info({:provider_updated, _id}, socket) do
    {:noreply, assign(socket, ai_providers: AiProvider.all())}
  end

  def handle_info({:provider_deleted, _id}, socket) do
    {:noreply, assign(socket, ai_providers: AiProvider.all())}
  end

  def handle_info({:conversation_deleted, name}, socket) do
    {:noreply,
     socket
     |> update(:conversations, &List.delete(&1, name))
     |> assign(confirm_delete_name: nil)}
  end

  def handle_info({:error, _reason}, socket) do
    {:noreply, socket}
  end
end
