defmodule ElixirAiWeb.AiProvidersLive do
  use ElixirAiWeb, :live_component
  import ElixirAiWeb.FormComponents
  alias ElixirAi.AiProvider

  def update(assigns, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ElixirAi.PubSub, "ai_providers")
    end

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:providers, fn -> AiProvider.all() end)
     |> assign_new(:show_form, fn -> false end)
     |> assign_new(
       :form_data,
       fn ->
         %{
           "name" => "",
           "model_name" => "",
           "api_token" => "",
           "completions_url" => "https://api.openai.com/v1/chat/completions"
         }
       end
     )
     |> assign_new(:error, fn -> nil end)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-lg font-semibold text-cyan-300">AI Providers</h1>
        <button
          phx-click="toggle_form"
          phx-target={@myself}
          class="px-3 py-1 rounded text-sm border border-cyan-900/40 bg-cyan-950/20 text-cyan-300 hover:border-cyan-700 hover:bg-cyan-950/40 transition-colors"
        >
          {if @show_form, do: "Cancel", else: "Add Provider"}
        </button>
      </div>

      <%= if @show_form do %>
        <form
          phx-submit="create_provider"
          phx-target={@myself}
          class="mb-8 space-y-2 p-4 rounded-lg border border-cyan-900/40 bg-cyan-950/10"
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
          <button
            type="submit"
            class="w-full px-4 py-2 rounded text-sm border border-cyan-900/40 bg-cyan-950/20 text-cyan-300 hover:border-cyan-700 hover:bg-cyan-950/40 transition-colors"
          >
            Create Provider
          </button>r
        </form>
      <% end %>

      <%= if @error do %>
        <p class="mb-4 text-sm text-red-400">{@error}</p>
      <% end %>

      <ul class="space-y-2">
        <%= if @providers == [] do %>
          <li class="text-sm text-cyan-700">No providers configured yet.</li>
        <% end %>
        <%= for provider <- @providers do %>
          <li class="p-4 rounded-lg border border-cyan-900/40 bg-cyan-950/20">
            <div class="flex items-start justify-between">
              <div class="flex-1">
                <h3 class="text-sm font-medium text-cyan-300">{provider.name}</h3>
                <p class="text-xs text-cyan-500 mt-1">Model: {provider.model_name}</p>
                <p class="text-xs text-cyan-600 mt-1 truncate">
                  Endpoint: {provider.completions_url}
                </p>
                <p class="text-xs text-cyan-600 mt-1">
                  Token: {String.slice(provider.api_token || "", 0..7)}***
                </p>
              </div>
            </div>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, error: nil)}
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
          completions_url: completions_url
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
                 "completions_url" => "https://api.openai.com/v1/chat/completions"
               }
             )
             |> assign(error: nil)}

          {:error, :already_exists} ->
            {:noreply, assign(socket, error: "A provider with that name already exists")}

          _ ->
            {:noreply, assign(socket, error: "Failed to create provider")}
        end
    end
  end

  def handle_info({:provider_added, _attrs}, socket) do
    {:noreply, assign(socket, providers: AiProvider.all())}
  end
end
