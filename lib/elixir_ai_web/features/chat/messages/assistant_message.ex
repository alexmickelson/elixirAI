defmodule ElixirAiWeb.AssistantMessage do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  import ElixirAiWeb.ToolMessages

  defp max_width_class, do: "max-w-full xl:max-w-300"

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil
  attr :tool_calls, :list, default: []
  attr :input_tokens, :integer, default: nil
  attr :output_tokens, :integer, default: nil
  attr :tokens_per_second, :float, default: nil

  def assistant_message(assigns) do
    assigns =
      assigns
      |> assign(
        :_reasoning_id,
        "reasoning-#{:erlang.phash2({assigns.content, assigns.reasoning_content, assigns.tool_calls})}"
      )
      |> assign(:_expanded, false)

    ~H"""
    <.message_bubble
      reasoning_id={@_reasoning_id}
      content={@content}
      reasoning_content={@reasoning_content}
      tool_calls={@tool_calls}
      expanded={@_expanded}
      input_tokens={@input_tokens}
      output_tokens={@output_tokens}
      tokens_per_second={@tokens_per_second}
    />
    """
  end

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil
  attr :tool_calls, :list, default: []

  # Renders the in-progress streaming message. Content and reasoning are rendered
  # entirely client-side via the MarkdownStream hook — the server sends push_event
  # chunks instead of re-rendering the full markdown on every token.
  def streaming_assistant_message(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-left min-w-0">
      <!-- Reasoning section — only shown once reasoning_content is non-empty.
           The div is always in the DOM so the hook mounts before chunks arrive. -->
      <div id="stream-reasoning-wrap">
        <%= if @reasoning_content && @reasoning_content != "" do %>
          <button
            type="button"
            class="flex items-center text-seafoam-500/60 hover:text-seafoam-300 transition-colors duration-150 cursor-pointer"
            phx-click={
              JS.toggle_class("collapsed", to: "#reasoning-stream")
              |> JS.toggle_class("rotate-180", to: "#reasoning-stream-chevron")
            }
            aria-label="Toggle reasoning"
          >
            <div class="flex items-center gap-1 text-seafoam-100/40 ps-2 mb-1">
              <span class="text-xs">reasoning</span>
              <svg
                id="reasoning-stream-chevron"
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
        <% end %>
        <div
          id="reasoning-stream"
          phx-hook="MarkdownStream"
          phx-update="ignore"
          data-event="reasoning_chunk"
          class={"reasoning-content block px-3 py-2 rounded-lg bg-seafoam-950/50 text-seafoam-400 italic text-xs #{max_width_class()} mb-1 markdown"}
        >
        </div>
      </div>
      <%= for tool_call <- @tool_calls do %>
        <.tool_message tool_call={tool_call} />
      <% end %>
      <div
        id="stream-content"
        phx-hook="MarkdownStream"
        phx-update="ignore"
        data-event="md_chunk"
        class={"w-fit px-3 py-2 rounded-lg #{max_width_class()} markdown bg-seafoam-950/50 overflow-x-auto"}
      >
      </div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :reasoning_content, :string, default: nil
  attr :tool_calls, :list, default: []
  attr :reasoning_id, :string, required: true
  attr :expanded, :boolean, default: false
  attr :input_tokens, :integer, default: nil
  attr :output_tokens, :integer, default: nil
  attr :tokens_per_second, :float, default: nil

  defp message_bubble(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-left min-w-0">
      <%= if @reasoning_content && @reasoning_content != "" do %>
        <button
          type="button"
          class="flex items-center text-seafoam-500/60 hover:text-seafoam-300 transition-colors duration-150 cursor-pointer"
          phx-click={
            JS.toggle_class("collapsed", to: "##{@reasoning_id}")
            |> JS.toggle_class("rotate-180", to: "##{@reasoning_id}-chevron")
          }
          aria-label="Toggle reasoning"
        >
          <div class="flex items-center gap-1 text-seafoam-100/40 ps-2 mb-1">
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
          phx-hook="MarkdownRender"
          phx-update="ignore"
          data-md={@reasoning_content}
          class={[
            "reasoning-content block px-3 py-2 rounded-lg bg-seafoam-950/50 text-seafoam-400 italic text-xs #{max_width_class()} mb-1 markdown",
            !@expanded && "collapsed"
          ]}
        >
        </div>
      <% end %>
      <%= for tool_call <- @tool_calls do %>
        <.tool_message tool_call={tool_call} />
      <% end %>
      <%= if @content && @content != "" do %>
        <div
          id={"#{@reasoning_id}-content"}
          phx-hook="MarkdownRender"
          phx-update="ignore"
          data-md={@content}
          class={"w-fit px-3 py-2 rounded-lg #{max_width_class()} markdown bg-seafoam-950/50 overflow-x-auto"}
        >
        </div>
      <% end %>
      <%= if @output_tokens do %>
        <div class="mt-0.5 ps-1 flex gap-2 text-[10px] text-seafoam-800 select-none">
          <span>{@input_tokens} in</span>
          <span>·</span>
          <span>{@output_tokens} out</span>
          <%= if @tokens_per_second do %>
            <span>·</span>
            <span>{@tokens_per_second} tok/s</span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
