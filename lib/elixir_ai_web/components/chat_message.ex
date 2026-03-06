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
  attr :tool_calls, :list, default: []

  def assistant_message(assigns) do
    assigns =
      assigns
      |> assign(:_reasoning_id, "reasoning-#{:erlang.phash2(assigns.content)}")
      |> assign(:_expanded, false)

    ~H"""
    <.message_bubble
      reasoning_id={@_reasoning_id}
      content={@content}
      reasoning_content={@reasoning_content}
      tool_calls={@tool_calls}
      expanded={@_expanded}
    />
    """
  end

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil
  attr :tool_calls, :list, default: []

  def streaming_assistant_message(assigns) do
    assigns =
      assigns
      |> assign(:_reasoning_id, "reasoning-stream")
      |> assign(:_expanded, true)

    ~H"""
    <.message_bubble
      reasoning_id={@_reasoning_id}
      content={@content}
      reasoning_content={@reasoning_content}
      tool_calls={@tool_calls}
      expanded={@_expanded}
    />
    """
  end

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil
  attr :tool_calls, :list, default: []
  attr :reasoning_id, :string, required: true
  attr :expanded, :boolean, default: false

  defp message_bubble(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-left">
      <%= if @reasoning_content && @reasoning_content != "" do %>
        <button
          type="button"
          class="flex items-center text-cyan-500/60 hover:text-cyan-300 transition-colors duration-150 cursor-pointer"
          phx-click={
            JS.toggle_class("collapsed", to: "##{@reasoning_id}")
            |> JS.toggle_class("rotate-180", to: "##{@reasoning_id}-chevron")
          }
          aria-label="Toggle reasoning"
        >
          <div class="flex items-center gap-1 text-cyan-100/40 ps-2 mb-1">
            <span class="text-xs">reasoning</span>
            <svg
              id={"#{@reasoning_id}-chevron"}
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              class={["w-3 h-3 transition-transform duration-300", !@expanded && "rotate-180"]}
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
          id={@reasoning_id}
          class={[
            "reasoning-content block px-3 py-2 rounded-lg bg-cyan-950/50 text-cyan-400 italic text-xs max-w-prose mb-1 markdown",
            !@expanded && "collapsed"
          ]}
        >
          {Markdown.render(@reasoning_content)}
        </div>
      <% end %>
      <%= for tool_call <- @tool_calls do %>
        <div class="mb-1 max-w-prose rounded-lg border border-cyan-900 bg-cyan-950/40 text-xs font-mono overflow-hidden">
          <div class="flex items-center gap-2 px-3 py-1 border-b border-cyan-900 bg-cyan-900/30 text-cyan-400">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3">
              <path fill-rule="evenodd" d="M6.28 5.22a.75.75 0 0 1 0 1.06L2.56 10l3.72 3.72a.75.75 0 0 1-1.06 1.06L.97 10.53a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Zm7.44 0a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L17.44 10l-3.72-3.72a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
            </svg>
            <span class="text-cyan-300 font-semibold">{tool_call.name}</span>
          </div>
          <%= if tool_call[:arguments] && tool_call[:arguments] != "" do %>
            <div class="px-3 py-2 text-cyan-500 border-b border-cyan-900/50">
              <span class="text-cyan-700 mr-1">args</span>{tool_call.arguments}
            </div>
          <% end %>
          <%= if Map.has_key?(tool_call, :result) do %>
            <div class="px-3 py-2 text-cyan-200">
              <span class="text-cyan-700 mr-1">result</span>{inspect(tool_call.result)}
            </div>
          <% end %>
          <%= if Map.has_key?(tool_call, :error) do %>
            <div class="px-3 py-2 text-red-400">
              <span class="text-red-600 mr-1">error</span>{tool_call.error}
            </div>
          <% end %>
        </div>
      <% end %>
      <%= if @content && @content != "" do %>
        <div class="inline-block px-3 py-2 rounded-lg max-w-prose markdown bg-cyan-950/50">
          {Markdown.render(@content)}
        </div>
      <% end %>
    </div>
    """
  end
end
