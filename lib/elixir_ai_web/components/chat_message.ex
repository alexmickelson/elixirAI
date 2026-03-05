defmodule ElixirAiWeb.ChatMessage do
  use Phoenix.Component
  alias ElixirAiWeb.Markdown
  alias Phoenix.LiveView.JS

  attr :content, :string, required: true

  def user_message(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-right">
      <div class="inline-block px-3 py-2 rounded-lg  bg-cyan-950 text-cyan-50 max-w-prose text-left">
        {@content}
      </div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil

  def assistant_message(assigns) do
    assigns = assign(assigns, :_reasoning_id, "reasoning-#{:erlang.phash2(assigns.content)}")

    ~H"""
    <div class="mb-2 text-sm text-left">
      <%= if @reasoning_content && @reasoning_content != "" do %>
        <button
          type="button"
          class="flex items-center text-cyan-500/60 hover:text-cyan-300 transition-colors duration-150 cursor-pointer"
          phx-click={
            JS.toggle_class("collapsed", to: "##{@_reasoning_id}")
            |> JS.toggle_class("rotate-180", to: "##{@_reasoning_id}-chevron")
          }
          aria-label="Toggle reasoning"
        >
          <div class="flex items-center gap-1 text-cyan-100/40 ps-2 mb-1">
            <span class="text-xs">reasoning</span>
            <svg
              id={"#{@_reasoning_id}-chevron"}
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class="w-3 h-3 transition-transform duration-300"
            >
              <path
                fill-rule="evenodd"
                d="M9.47 6.47a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 1 1-1.06 1.06L10 8.06l-3.72 3.72a.75.75 0 0 1-1.06-1.06l4.25-4.25Z"
                clip-rule="evenodd"
              />
            </svg>
          </div>
        </button>
        <div
          id={@_reasoning_id}
          class="reasoning-content block px-3 py-2 rounded-lg bg-cyan-950/50 text-cyan-400 italic text-xs max-w-prose mb-1 markdown"
        >
          {Markdown.render(@reasoning_content)}
        </div>
      <% end %>
      <div class="inline-block px-3 py-2 rounded-lg  max-w-prose markdown bg-cyan-950/50">
        {Markdown.render(@content)}
      </div>
    </div>
    """
  end
end
