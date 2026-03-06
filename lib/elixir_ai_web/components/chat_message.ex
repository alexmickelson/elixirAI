defmodule ElixirAiWeb.ChatMessage do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :content, :string, required: true
  attr :tool_call_id, :string, required: true

  def tool_result_message(assigns) do
    ~H"""
    <div class="mb-1 max-w-prose rounded-lg border border-cyan-900/40 bg-cyan-950/20 text-xs font-mono overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 border-b border-cyan-900/40 bg-cyan-900/10 text-cyan-600">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3 shrink-0">
          <path fill-rule="evenodd" d="M10 2a.75.75 0 0 1 .75.75v.258a33.186 33.186 0 0 1 6.668 2.372.75.75 0 1 1-.636 1.354 31.66 31.66 0 0 0-1.598-.632l1.44 7.402a.75.75 0 0 1-.26.726A18.698 18.698 0 0 1 10 15.75a18.698 18.698 0 0 1-6.364-1.518.75.75 0 0 1-.26-.726l1.44-7.402a31.66 31.66 0 0 0-1.598.632.75.75 0 1 1-.636-1.354 33.186 33.186 0 0 1 6.668-2.372V2.75A.75.75 0 0 1 10 2Z" clip-rule="evenodd" />
        </svg>
        <span class="text-cyan-600/70 flex-1 truncate">tool result</span>
        <span class="text-cyan-800 text-[10px] truncate max-w-[12rem]">{@tool_call_id}</span>
      </div>
      <div class="px-3 py-2">
        <pre class="text-cyan-500/70 whitespace-pre-wrap break-all">{@content}</pre>
      </div>
    </div>
    """
  end

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
      |> assign(:_reasoning_id, "reasoning-#{:erlang.phash2({assigns.content, assigns.reasoning_content, assigns.tool_calls})}")
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
    <div class="mb-2 text-sm text-left">
      <!-- Reasoning section — only shown once reasoning_content is non-empty.
           The div is always in the DOM so the hook mounts before chunks arrive. -->
      <div id="stream-reasoning-wrap">
        <%= if @reasoning_content && @reasoning_content != "" do %>
          <button
            type="button"
            class="flex items-center text-cyan-500/60 hover:text-cyan-300 transition-colors duration-150 cursor-pointer"
            phx-click={
              JS.toggle_class("collapsed", to: "#reasoning-stream")
              |> JS.toggle_class("rotate-180", to: "#reasoning-stream-chevron")
            }
            aria-label="Toggle reasoning"
          >
            <div class="flex items-center gap-1 text-cyan-100/40 ps-2 mb-1">
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
          class="reasoning-content block px-3 py-2 rounded-lg bg-cyan-950/50 text-cyan-400 italic text-xs max-w-prose mb-1 markdown"
        ></div>
      </div>
      <%= for tool_call <- @tool_calls do %>
        <.tool_call_item tool_call={tool_call} />
      <% end %>
      <div
        id="stream-content"
        phx-hook="MarkdownStream"
        phx-update="ignore"
        data-event="md_chunk"
        class="inline-block px-3 py-2 rounded-lg max-w-prose markdown bg-cyan-950/50"
      ></div>
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
          phx-hook="MarkdownRender"
          phx-update="ignore"
          data-md={@reasoning_content}
          class={[
            "reasoning-content block px-3 py-2 rounded-lg bg-cyan-950/50 text-cyan-400 italic text-xs max-w-prose mb-1 markdown",
            !@expanded && "collapsed"
          ]}
        ></div>
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
          class="inline-block px-3 py-2 rounded-lg max-w-prose markdown bg-cyan-950/50"
        ></div>
      <% end %>
    </div>
    """
  end

  # Dispatches to the appropriate tool call component based on result state
  attr :tool_call, :map, required: true

  defp tool_call_item(%{tool_call: tool_call} = assigns) do
    cond do
      Map.has_key?(tool_call, :error) ->
        assigns =
          assigns
          |> assign(:name, tool_call.name)
          |> assign(:arguments, tool_call[:arguments] || "")
          |> assign(:error, tool_call.error)

        ~H"<.error_tool_call name={@name} arguments={@arguments} error={@error} />"

      Map.has_key?(tool_call, :result) ->
        assigns =
          assigns
          |> assign(:name, tool_call.name)
          |> assign(:arguments, tool_call[:arguments] || "")
          |> assign(:result, tool_call.result)

        ~H"<.success_tool_call name={@name} arguments={@arguments} result={@result} />"

      true ->
        assigns =
          assigns
          |> assign(:name, tool_call.name)
          |> assign(:arguments, tool_call[:arguments] || "")

        ~H"<.pending_tool_call name={@name} arguments={@arguments} />"
    end
  end

  attr :name, :string, required: true
  attr :arguments, :string, default: ""

  defp pending_tool_call(assigns) do
    ~H"""
    <div class="mb-1 max-w-prose rounded-lg border border-cyan-900 bg-cyan-950/40 text-xs font-mono overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 border-b border-cyan-900 bg-cyan-900/30 text-cyan-400">
        <.tool_call_icon />
        <span class="text-cyan-300 font-semibold flex-1">{@name}</span>
        <span class="flex items-center gap-1 text-cyan-600">
          <span class="w-1.5 h-1.5 rounded-full bg-cyan-600 animate-pulse inline-block"></span>
          <span class="text-[10px]">running</span>
        </span>
      </div>
      <.tool_call_args arguments={@arguments} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :arguments, :string, default: ""
  attr :result, :any, required: true

  defp success_tool_call(assigns) do
    assigns =
      assign(assigns, :result_str, case assigns.result do
        s when is_binary(s) -> s
        other -> inspect(other, pretty: true, limit: :infinity)
      end)

    ~H"""
    <div class="mb-1 max-w-prose rounded-lg border border-cyan-900 bg-cyan-950/40 text-xs font-mono overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 border-b border-cyan-900 bg-cyan-900/30 text-cyan-400">
        <.tool_call_icon />
        <span class="text-cyan-300 font-semibold flex-1">{@name}</span>
        <span class="flex items-center gap-1 text-emerald-500">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3">
            <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
          </svg>
          <span class="text-[10px]">done</span>
        </span>
      </div>
      <.tool_call_args arguments={@arguments} />
      <div class="px-3 py-2">
        <div class="text-cyan-700 mb-1 uppercase tracking-wider text-[10px]">result</div>
        <pre class="text-emerald-300/80 whitespace-pre-wrap break-all">{@result_str}</pre>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :arguments, :string, default: ""
  attr :error, :string, required: true

  defp error_tool_call(assigns) do
    ~H"""
    <div class="mb-1 max-w-prose rounded-lg border border-red-900/50 bg-cyan-950/40 text-xs font-mono overflow-hidden">
      <div class="flex items-center gap-2 px-3 py-1.5 border-b border-red-900/50 bg-red-900/20 text-cyan-400">
        <.tool_call_icon />
        <span class="text-cyan-300 font-semibold flex-1">{@name}</span>
        <span class="flex items-center gap-1 text-red-500">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3">
            <path d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm0-10a.75.75 0 0 1 .75.75v3a.75.75 0 0 1-1.5 0v-3A.75.75 0 0 1 8 5Zm0 6.5a.75.75 0 1 1 0-1.5.75.75 0 0 1 0 1.5Z" />
          </svg>
          <span class="text-[10px]">error</span>
        </span>
      </div>
      <.tool_call_args arguments={@arguments} />
      <div class="px-3 py-2 bg-red-950/20">
        <div class="text-red-700 mb-1 uppercase tracking-wider text-[10px]">error</div>
        <pre class="text-red-400 whitespace-pre-wrap break-all">{@error}</pre>
      </div>
    </div>
    """
  end

  attr :arguments, :string, default: ""

  defp tool_call_args(%{arguments: args} = assigns) when args != "" do
    assigns =
      assign(assigns, :pretty_args, case Jason.decode(args) do
        {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
        _ -> args
      end)

    ~H"""
    <div class="px-3 py-2 border-b border-cyan-900/50">
      <div class="text-cyan-700 mb-1 uppercase tracking-wider text-[10px]">arguments</div>
      <pre class="text-cyan-400 whitespace-pre-wrap break-all">{@pretty_args}</pre>
    </div>
    """
  end

  defp tool_call_args(assigns), do: ~H""

  defp tool_call_icon(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3 shrink-0">
      <path fill-rule="evenodd" d="M6.28 5.22a.75.75 0 0 1 0 1.06L2.56 10l3.72 3.72a.75.75 0 0 1-1.06 1.06L.97 10.53a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Zm7.44 0a.75.75 0 0 1 1.06 0l4.25 4.25a.75.75 0 0 1 0 1.06l-4.25 4.25a.75.75 0 0 1-1.06-1.06L17.44 10l-3.72-3.72a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
    </svg>
    """
  end
end
