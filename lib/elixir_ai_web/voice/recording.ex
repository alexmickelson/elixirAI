defmodule ElixirAiWeb.Voice.Recording do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :state, :atom, required: true

  def recording(assigns) do
    ~H"""
    <div class="p-4 flex flex-col gap-3">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <%= if @state == :idle do %>
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4 text-seafoam-500 shrink-0"
              viewBox="0 0 24 24"
              fill="currentColor"
            >
              <path d="M12 1a4 4 0 0 1 4 4v7a4 4 0 0 1-8 0V5a4 4 0 0 1 4-4zm0 2a2 2 0 0 0-2 2v7a2 2 0 1 0 4 0V5a2 2 0 0 0-2-2zm-7 9a7 7 0 0 0 14 0h2a9 9 0 0 1-8 8.94V23h-2v-2.06A9 9 0 0 1 3 12H5z" />
            </svg>
            <span class="text-seafoam-400 font-semibold text-sm">Voice Input</span>
          <% end %>
          <%= if @state == :recording do %>
            <span class="relative flex h-3 w-3 shrink-0">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-500 opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-red-500"></span>
            </span>
            <span class="text-seafoam-50 font-semibold text-sm">Recording</span>
          <% end %>
          <%= if @state == :processing do %>
            <span class="relative flex h-3 w-3 shrink-0">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-seafoam-400 opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-seafoam-400"></span>
            </span>
            <span class="text-seafoam-50 font-semibold text-sm">Processing…</span>
          <% end %>
        </div>
        <button
          phx-click="minimize"
          title="Minimize"
          class="p-1 rounded-lg text-seafoam-600 hover:text-seafoam-300 hover:bg-seafoam-800/50 transition-colors"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-4 w-4"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M5 12h14" />
          </svg>
        </button>
      </div>
      <%= if @state in [:recording, :processing] do %>
        <div id="voice-viz-wrapper" phx-update="ignore">
          <canvas id="voice-viz-canvas" height="72" class="w-full rounded-lg bg-seafoam-950 block">
          </canvas>
        </div>
      <% end %>
      <%= if @state == :idle do %>
        <button
          phx-click={JS.dispatch("voice:start", to: "#voice-control-hook")}
          class="w-full flex items-center justify-between px-3 py-1.5 rounded-lg bg-seafoam-700 hover:bg-seafoam-600 text-seafoam-50 text-xs font-medium transition-colors"
        >
          <span>Start Recording</span>
          <kbd class="text-seafoam-300 bg-seafoam-800 border border-seafoam-600 px-1.5 py-0.5 rounded font-mono">
            Ctrl+Space
          </kbd>
        </button>
      <% end %>
      <%= if @state == :recording do %>
        <button
          phx-click={JS.dispatch("voice:stop", to: "#voice-control-hook")}
          class="w-full flex items-center justify-between px-3 py-1.5 rounded-lg bg-seafoam-800 hover:bg-seafoam-700 text-seafoam-50 text-xs font-medium transition-colors border border-seafoam-700"
        >
          <span>Stop Recording</span>
          <kbd class="text-seafoam-300 bg-seafoam-900 border border-seafoam-700 px-1.5 py-0.5 rounded font-mono">
            Space
          </kbd>
        </button>
      <% end %>
    </div>
    """
  end
end
