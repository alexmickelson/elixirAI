defmodule ElixirAiWeb.ChatMessage do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  import ElixirAiWeb.JsonDisplay

  defp max_width_class, do: "max-w-full xl:max-w-300"

  attr :content, :string, required: true
  attr :tool_call_id, :string, required: true

  def tool_result_message(assigns) do
    ~H"""
    <div class={"mb-1 #{max_width_class()} rounded-lg border border-seafoam-900/40 bg-seafoam-950/20 text-xs font-mono overflow-hidden"}>
      <div class="flex items-center gap-2 px-3 py-1.5 border-b border-seafoam-900/40 bg-seafoam-900/10 text-seafoam-600">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          class="w-3 h-3 shrink-0"
        >
          <path
            fill-rule="evenodd"
            d="M10 2a.75.75 0 0 1 .75.75v.258a33.186 33.186 0 0 1 6.668 2.372.75.75 0 1 1-.636 1.354 31.66 31.66 0 0 0-1.598-.632l1.44 7.402a.75.75 0 0 1-.26.726A18.698 18.698 0 0 1 10 15.75a18.698 18.698 0 0 1-6.364-1.518.75.75 0 0 1-.26-.726l1.44-7.402a31.66 31.66 0 0 0-1.598.632.75.75 0 1 1-.636-1.354 33.186 33.186 0 0 1 6.668-2.372V2.75A.75.75 0 0 1 10 2Z"
            clip-rule="evenodd"
          />
        </svg>
        <span class="text-seafoam-600/70 flex-1 truncate">tool result</span>
        <span class="text-seafoam-800 text-[10px] truncate max-w-[12rem]">{@tool_call_id}</span>
      </div>
      <div class="px-3 py-2">
        <pre class="text-seafoam-500/70 whitespace-pre-wrap break-all">{@content}</pre>
      </div>
    </div>
    """
  end

  attr :content, :string, required: true

  def user_message(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-right">
      <div class={"w-fit px-3 py-2 rounded-lg  bg-seafoam-950 text-seafoam-50 #{max_width_class()} text-left"}>
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
        <.tool_call_item tool_call={tool_call} />
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
        <.tool_call_item tool_call={tool_call} />
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
    </div>
    """
  end

  # Dispatches to the unified tool_call_card component, determining state from the map keys:
  #   :error key  → :error   (runtime failure)
  #   :result key → :success (completed)
  #   :index key  → :pending (streaming in-progress)
  #   none        → :called  (DB-loaded; result is a separate message)
  attr :tool_call, :map, required: true

  defp tool_call_item(%{tool_call: tool_call} = assigns) do
    state =
      cond do
        Map.has_key?(tool_call, :error) -> :error
        Map.has_key?(tool_call, :result) -> :success
        Map.has_key?(tool_call, :index) -> :pending
        true -> :called
      end

    assigns =
      assigns
      |> assign(:_state, state)
      |> assign(:_name, tool_call.name)
      |> assign(:_arguments, tool_call[:arguments])
      |> assign(:_result, tool_call[:result])
      |> assign(:_error, tool_call[:error])

    ~H"<.tool_call_card
  state={@_state}
  name={@_name}
  arguments={@_arguments}
  result={@_result}
  error={@_error}
/>"
  end

  attr :state, :atom, required: true
  attr :name, :string, required: true
  attr :arguments, :any, default: nil
  attr :result, :any, default: nil
  attr :error, :string, default: nil

  defp tool_call_card(assigns) do
    assigns =
      assigns
      |> assign(:_id, "tc-#{:erlang.phash2({assigns.name, assigns.arguments})}")
      |> assign(:_truncated, truncate_args(assigns.arguments))
      |> assign(
        :_result_str,
        case assigns.result do
          nil -> nil
          s when is_binary(s) -> s
          other -> inspect(other, pretty: true, limit: :infinity)
        end
      )

    ~H"""
    <div
      id={@_id}
      class={[
        "mb-1 #{max_width_class()} rounded-lg border text-xs font-mono overflow-hidden bg-seafoam-950/40",
        @state == :error && "border-red-900/50",
        @state == :called && "border-seafoam-900/60",
        @state in [:pending, :success] && "border-seafoam-900"
      ]}
    >
      <div
        class={[
          "flex items-center gap-2 px-3 py-1.5 border-b text-seafoam-400",
          @_truncated && "cursor-pointer select-none",
          @state == :error && "border-red-900/50 bg-red-900/20",
          @state == :called && "border-seafoam-900/60 bg-seafoam-900/20",
          @state in [:pending, :success] && "border-seafoam-900 bg-seafoam-900/30"
        ]}
        phx-click={
          @_truncated &&
            JS.toggle_class("hidden", to: "##{@_id}-args")
            |> JS.toggle_class("rotate-180", to: "##{@_id}-chevron")
        }
      >
        <.tool_call_icon />
        <span class="text-seafoam-400 font-semibold shrink-0">{@name}</span>
        <span :if={@_truncated} class="text-seafoam-500 truncate flex-1 min-w-0 ml-1">
          <.json_display json={@_truncated} inline />
        </span>
        <span :if={!@_truncated} class="flex-1" />
        <svg
          :if={@_truncated}
          id={"#{@_id}-chevron"}
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 16 16"
          fill="currentColor"
          class="w-3 h-3 shrink-0 mx-1 text-seafoam-700 transition-transform duration-200"
        >
          <path
            fill-rule="evenodd"
            d="M4.22 6.22a.75.75 0 0 1 1.06 0L8 8.94l2.72-2.72a.75.75 0 1 1 1.06 1.06l-3.25 3.25a.75.75 0 0 1-1.06 0L4.22 7.28a.75.75 0 0 1 0-1.06Z"
            clip-rule="evenodd"
          />
        </svg>
        <span :if={@state == :called} class="flex items-center gap-1 text-seafoam-500/50 shrink-0">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3 h-3"
          >
            <path
              fill-rule="evenodd"
              d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z"
              clip-rule="evenodd"
            />
          </svg>
          <span class="text-[10px]">called</span>
        </span>
        <span :if={@state == :pending} class="flex items-center gap-1 text-seafoam-600 shrink-0">
          <span class="w-1.5 h-1.5 rounded-full bg-seafoam-600 animate-pulse inline-block"></span>
          <span class="text-[10px]">running</span>
        </span>
        <span :if={@state == :success} class="flex items-center gap-1 text-emerald-500 shrink-0">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3 h-3"
          >
            <path
              fill-rule="evenodd"
              d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z"
              clip-rule="evenodd"
            />
          </svg>
          <span class="text-[10px]">done</span>
        </span>
        <span :if={@state == :error} class="flex items-center gap-1 text-red-500 shrink-0">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="currentColor"
            class="w-3 h-3"
          >
            <path d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm0-10a.75.75 0 0 1 .75.75v3a.75.75 0 0 1-1.5 0v-3A.75.75 0 0 1 8 5Zm0 6.5a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Z" />
          </svg>
          <span class="text-[10px]">error</span>
        </span>
      </div>
      <div id={"#{@_id}-args"} class="hidden">
        <.tool_call_args arguments={@arguments} />
      </div>
      <div :if={@state == :success} class="px-3 py-2">
        <div class="text-seafoam-700 mb-1 uppercase tracking-wider text-[10px]">result</div>
        <pre class="text-emerald-300/80 whitespace-pre-wrap break-all">{@_result_str}</pre>
      </div>
      <div :if={@state == :error} class="px-3 py-2 bg-red-950/20">
        <div class="text-red-700 mb-1 uppercase tracking-wider text-[10px]">error</div>
        <pre class="text-red-400 whitespace-pre-wrap break-all">{@error}</pre>
      </div>
    </div>
    """
  end

  defp truncate_args(nil), do: nil
  defp truncate_args(""), do: nil

  defp truncate_args(args) when is_binary(args) do
    compact =
      case Jason.decode(args) do
        {:ok, decoded} -> Jason.encode!(decoded)
        _ -> args
      end

    if String.length(compact) > 72, do: String.slice(compact, 0, 69) <> "\u2026", else: compact
  end

  defp truncate_args(args) do
    compact = Jason.encode!(args)
    if String.length(compact) > 72, do: String.slice(compact, 0, 69) <> "\u2026", else: compact
  end

  attr :arguments, :any, default: nil

  defp tool_call_args(%{arguments: args} = assigns) when not is_nil(args) and args != "" do
    ~H"""
    <div class="px-3 py-2 border-b border-seafoam-900/50">
      <div class="text-seafoam-500 mb-1 uppercase tracking-wider text-[10px]">arguments</div>
      <.json_display json={@arguments} />
    </div>
    """
  end

  defp tool_call_args(assigns), do: ~H""

  defp tool_call_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-3 h-3 shrink-0"
    >
      <path
        fill-rule="evenodd"
        d="M6.28 5.22a.75.75 0 0 1 0 1.06L2.56 10l3.72 3.72a.75.75 0 0 1-1.06 1.06L.97 10.53a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Zm7.44 0a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L17.44 10l-3.72-3.72a.75.75 0 0 1 0-1.06Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end
end
