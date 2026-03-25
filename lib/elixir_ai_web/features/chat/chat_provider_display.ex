defmodule ElixirAiWeb.ChatProviderDisplay do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :provider, :any, default: nil
  attr :providers, :list, default: []

  def chat_provider_display(assigns) do
    ~H"""
    <div class="relative" id="provider-display">
      <button
        type="button"
        phx-click={JS.toggle(to: "#provider-dropdown")}
        class="flex items-center gap-2 text-xs min-w-0 cursor-pointer hover:opacity-80 transition-opacity"
      >
        <div class="flex items-center gap-1.5 px-2 py-1 rounded bg-seafoam-950/50 border border-seafoam-900/40 min-w-0 select-none">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-3 h-3 shrink-0 text-seafoam-600"
          >
            <path d="M10 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 8a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM1.49 15.326a.78.78 0 0 1-.358-.442 3 3 0 0 1 4.308-3.516 6.484 6.484 0 0 0-1.905 3.959c-.023.222-.014.442.025.654a4.97 4.97 0 0 1-2.07-.655ZM16.44 15.98a4.97 4.97 0 0 0 2.07-.654.78.78 0 0 0 .357-.442 3 3 0 0 0-4.308-3.516 6.484 6.484 0 0 1 1.907 3.96 2.32 2.32 0 0 1-.026.654ZM18 8a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM5.304 16.19a.844.844 0 0 1-.277-.71 5 5 0 0 1 9.947 0 .843.843 0 0 1-.277.71A6.975 6.975 0 0 1 10 18a6.974 6.974 0 0 1-4.696-1.81Z" />
          </svg>
          <%= if @provider do %>
            <span class="text-seafoam-400 font-medium truncate">{@provider.name}</span>
            <span class="text-seafoam-800">·</span>
            <span class="text-seafoam-600 truncate">{@provider.model_name}</span>
          <% else %>
            <span class="text-seafoam-800 italic">No provider</span>
          <% end %>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            class="w-2.5 h-2.5 text-seafoam-700 ml-0.5 shrink-0"
          >
            <path
              fill-rule="evenodd"
              d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
      </button>
      <div
        id="provider-dropdown"
        class="hidden absolute right-0 top-full mt-1 z-50 min-w-max bg-gray-950 border border-seafoam-900/40 rounded shadow-xl overflow-hidden"
        phx-click-away={JS.hide(to: "#provider-dropdown")}
      >
        <%= if @providers == [] do %>
          <div class="px-3 py-2 text-xs text-gray-500 italic">No providers configured</div>
        <% else %>
          <%= for p <- @providers do %>
            <button
              type="button"
              phx-click={
                JS.hide(to: "#provider-dropdown")
                |> JS.push("change_provider", value: %{id: p.id})
              }
              class={[
                "flex flex-col px-3 py-2 text-left w-full text-xs hover:bg-seafoam-950/60 transition-colors",
                if(@provider && @provider.name == p.name,
                  do: "text-seafoam-400",
                  else: "text-gray-300"
                )
              ]}
            >
              <span class="font-medium">{p.name}</span>
              <span class={
                if @provider && @provider.name == p.name,
                  do: "text-seafoam-700",
                  else: "text-gray-500"
              }>
                {p.model_name}
              </span>
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
