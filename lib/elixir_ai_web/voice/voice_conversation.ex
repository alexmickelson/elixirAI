defmodule ElixirAiWeb.Voice.VoiceConversation do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  import ElixirAiWeb.ChatMessage
  import ElixirAiWeb.Spinner

  attr :messages, :list, required: true
  attr :streaming_response, :any, default: nil
  attr :ai_error, :string, default: nil

  def voice_conversation(assigns) do
    ~H"""
    <div class="flex flex-col flex-1 overflow-hidden">
      <div class="flex items-center justify-between px-4 pt-4 pb-2">
        <span class="text-seafoam-300 font-semibold text-sm">Voice Chat</span>
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
      <%= if @ai_error do %>
        <div class="mx-4 mt-1 px-3 py-2 rounded text-sm text-red-400 bg-red-950/40" role="alert">
          AI error: {@ai_error}
        </div>
      <% end %>
      <div
        id="voice-chat-messages"
        phx-hook="ScrollBottom"
        class="flex-1 overflow-y-auto px-4 py-2 space-y-1"
      >
        <%= for msg <- @messages do %>
          <%= cond do %>
            <% msg.role == :user -> %>
              <.user_message content={Map.get(msg, :content) || ""} />
            <% msg.role == :tool -> %>
              <.tool_result_message
                content={Map.get(msg, :content) || ""}
                tool_call_id={Map.get(msg, :tool_call_id) || ""}
              />
            <% true -> %>
              <.assistant_message
                content={Map.get(msg, :content) || ""}
                reasoning_content={Map.get(msg, :reasoning_content)}
                tool_calls={Map.get(msg, :tool_calls) || []}
              />
          <% end %>
        <% end %>
        <%= if @streaming_response do %>
          <.streaming_assistant_message
            content={@streaming_response.content}
            reasoning_content={@streaming_response.reasoning_content}
            tool_calls={@streaming_response.tool_calls}
          />
          <.spinner />
        <% end %>
      </div>
      <div class="px-4 pb-3 pt-2 flex items-center justify-between gap-2">
        <button
          phx-click="dismiss_transcription"
          class="text-xs text-seafoam-500 hover:text-seafoam-300 transition-colors"
        >
          Dismiss
        </button>
        <button
          phx-click={JS.dispatch("voice:start", to: "#voice-control-hook")}
          title="Voice input (Ctrl+Space)"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-seafoam-700 hover:bg-seafoam-600 text-seafoam-50 text-xs font-medium transition-colors"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-3.5 w-3.5"
            viewBox="0 0 24 24"
            fill="currentColor"
          >
            <path d="M12 1a4 4 0 0 1 4 4v7a4 4 0 0 1-8 0V5a4 4 0 0 1 4-4zm0 2a2 2 0 0 0-2 2v7a2 2 0 1 0 4 0V5a2 2 0 0 0-2-2zm-7 9a7 7 0 0 0 14 0h2a9 9 0 0 1-8 8.94V23h-2v-2.06A9 9 0 0 1 3 12H5z" />
          </svg>
          <span>Record</span>
        </button>
      </div>
    </div>
    """
  end
end
