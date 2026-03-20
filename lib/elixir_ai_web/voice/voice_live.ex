defmodule ElixirAiWeb.VoiceLive do
  use ElixirAiWeb, :live_view
  require Logger

  def mount(_params, _session, socket) do
    {:ok, assign(socket, state: :idle, transcription: nil), layout: false}
  end

  def render(assigns) do
    ~H"""
    <div id="voice-control-hook" phx-hook="VoiceControl">
      <div class="fixed top-4 right-4 w-72 bg-cyan-950/95 border border-cyan-800 rounded-2xl shadow-2xl z-50 p-4 flex flex-col gap-3 backdrop-blur">
        <div class="flex items-center gap-3">
          <%= if @state == :idle do %>
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 text-cyan-500 shrink-0" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 1a4 4 0 0 1 4 4v7a4 4 0 0 1-8 0V5a4 4 0 0 1 4-4zm0 2a2 2 0 0 0-2 2v7a2 2 0 1 0 4 0V5a2 2 0 0 0-2-2zm-7 9a7 7 0 0 0 14 0h2a9 9 0 0 1-8 8.94V23h-2v-2.06A9 9 0 0 1 3 12H5z"/>
            </svg>
            <span class="text-cyan-400 font-semibold text-sm">Voice Input</span>
          <% end %>
          <%= if @state == :recording do %>
            <span class="relative flex h-3 w-3 shrink-0">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-500 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-red-500"></span>
            </span>
            <span class="text-cyan-50 font-semibold text-sm">Recording</span>
          <% end %>
          <%= if @state == :processing do %>
            <span class="relative flex h-3 w-3 shrink-0">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-cyan-400 opacity-75"></span>
              <span class="relative inline-flex rounded-full h-3 w-3 bg-cyan-400"></span>
            </span>
            <span class="text-cyan-50 font-semibold text-sm">Processing…</span>
          <% end %>
          <%= if @state == :transcribed do %>
            <span class="text-cyan-300 font-semibold text-sm">Transcription</span>
          <% end %>
        </div>
        <%= if @state in [:recording, :processing] do %>
          <div id="voice-viz-wrapper" phx-update="ignore">
            <canvas id="voice-viz-canvas" height="72" class="w-full rounded-lg bg-cyan-950 block">
            </canvas>
          </div>
        <% end %>
        <%= if @state == :transcribed do %>
          <div class="rounded-xl bg-cyan-900/60 border border-cyan-700 px-3 py-2">
            <p class="text-sm text-cyan-50 leading-relaxed">{@transcription}</p>
          </div>
        <% end %>
        <%= if @state == :idle do %>
          <button
            phx-click={JS.dispatch("voice:start", to: "#voice-control-hook")}
            class="w-full flex items-center justify-between px-3 py-1.5 rounded-lg bg-cyan-700 hover:bg-cyan-600 text-cyan-50 text-xs font-medium transition-colors"
          >
            <span>Start Recording</span>
            <kbd class="text-cyan-300 bg-cyan-800 border border-cyan-600 px-1.5 py-0.5 rounded font-mono">Ctrl+Space</kbd>
          </button>
        <% end %>
        <%= if @state == :recording do %>
          <button
            phx-click={JS.dispatch("voice:stop", to: "#voice-control-hook")}
            class="w-full flex items-center justify-between px-3 py-1.5 rounded-lg bg-cyan-800 hover:bg-cyan-700 text-cyan-50 text-xs font-medium transition-colors border border-cyan-700"
          >
            <span>Stop Recording</span>
            <kbd class="text-cyan-300 bg-cyan-900 border border-cyan-700 px-1.5 py-0.5 rounded font-mono">Space</kbd>
          </button>
        <% end %>
        <%= if @state == :transcribed do %>
          <button
            phx-click="dismiss_transcription"
            class="text-xs text-cyan-500 hover:text-cyan-300 transition-colors text-center w-full"
          >
            Dismiss
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def handle_event("recording_started", _params, socket) do
    {:noreply, assign(socket, state: :recording)}
  end

  def handle_event("audio_recorded", %{"data" => base64, "mime_type" => mime_type}, socket) do
    case Base.decode64(base64) do
      {:ok, audio_binary} ->
        Logger.info(
          "VoiceLive: received #{byte_size(audio_binary)} bytes of audio (#{mime_type})"
        )

        ElixirAi.AudioProcessing.submit(audio_binary, mime_type, self())
        {:noreply, assign(socket, state: :processing)}

      :error ->
        Logger.error("VoiceLive: failed to decode base64 audio data")
        {:noreply, assign(socket, state: :idle)}
    end
  end

  def handle_event("recording_error", %{"reason" => reason}, socket) do
    Logger.warning("VoiceLive: recording error: #{reason}")
    {:noreply, assign(socket, state: :idle)}
  end

  def handle_event("dismiss_transcription", _params, socket) do
    {:noreply, assign(socket, state: :idle, transcription: nil)}
  end

  def handle_info({:transcription_result, {:ok, text}}, socket) do
    {:noreply, assign(socket, state: :transcribed, transcription: text)}
  end

  def handle_info({:transcription_result, {:error, reason}}, socket) do
    Logger.error("VoiceLive: transcription failed: #{inspect(reason)}")
    {:noreply, assign(socket, state: :idle)}
  end
end
