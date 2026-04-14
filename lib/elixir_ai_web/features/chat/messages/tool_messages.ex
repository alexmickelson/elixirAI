defmodule ElixirAiWeb.ToolMessages do
  use Phoenix.Component
  alias Phoenix.LiveView.JS
  import ElixirAiWeb.JsonDisplay

  defp max_width_class, do: "max-w-full xl:max-w-300"

  @tool_output_tuple_pattern ~r/^\{:([a-z][a-z0-9_]*),\s*"(.*)"\}$/s
  @string_unescape_pattern ~r/\\(n|t|r|\\|")/

  attr :tool_call, :map, required: true
  attr :result, :map, default: nil

  def tool_message(%{tool_call: tool_call} = assigns) do
    state =
      cond do
        Map.has_key?(tool_call, :error) -> :error
        Map.has_key?(tool_call, :index) -> :pending
        assigns.result != nil -> :success
        true -> :called
      end

    result_content =
      case assigns.result do
        %{content: c} -> c
        nil -> nil
      end

    {is_cmd, cmd_atom, cmd_body} = parse_command_result(result_content)
    id = "tm-#{:erlang.phash2({tool_call[:id], tool_call.name, tool_call[:arguments]})}"

    assigns =
      assigns
      |> assign(:_state, state)
      |> assign(:_id, id)
      |> assign(:_name, tool_call.name)
      |> assign(:_arguments, tool_call[:arguments])
      |> assign(:_approval_decision, tool_call[:approval_decision])
      |> assign(:_approval_justification, tool_call[:approval_justification])
      |> assign(:_reasoning_content, tool_call[:reasoning_content])
      |> assign(:_result_content, result_content)
      |> assign(:_is_cmd, is_cmd)
      |> assign(:_cmd_atom, cmd_atom)
      |> assign(:_cmd_body, cmd_body)
      |> assign(:_truncated, truncate_args(tool_call[:arguments]))
      |> assign(:_error, tool_call[:error])

    ~H"""
    <div
      id={@_id}
      class={[
        "mb-1 #{max_width_class()} rounded-lg border text-xs font-mono overflow-hidden bg-seafoam-950/40",
        @_state == :error && "border-red-900/50",
        @_state == :called && "border-seafoam-900/60",
        @_state in [:pending, :success] && "border-seafoam-900"
      ]}
    >
      <div
        class={[
          "flex items-center gap-2 px-3 py-1.5 border-b cursor-pointer select-none",
          @_state == :error && "border-red-900/50 bg-red-900/20 text-red-400",
          @_state == :called && "border-seafoam-900/60 bg-seafoam-900/20 text-seafoam-400",
          @_state in [:pending, :success] && "border-seafoam-900 bg-seafoam-900/30 text-seafoam-400"
        ]}
        phx-click={
          JS.toggle_class("hidden", to: "##{@_id}-body")
          |> JS.toggle_class("rotate-180", to: "##{@_id}-chevron")
        }
      >
        <.tool_call_icon />
        <span class="font-semibold shrink-0">{@_name}</span>
        <span :if={@_truncated} class="text-seafoam-500 truncate flex-1 min-w-0 ml-1">
          <.json_display json={@_truncated} inline />
        </span>
        <span :if={!@_truncated} class="flex-1" />
        <svg
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
        <span
          :if={@_approval_decision}
          class={[
            "shrink-0 text-[10px]",
            @_approval_decision == "auto_allowed" && "text-seafoam-600/70",
            @_approval_decision == "approved" && "text-emerald-500/80",
            @_approval_decision in ["denied", "timed_out"] && "text-red-400/80"
          ]}
        >
          {String.replace(@_approval_decision, "_", " ")}
        </span>
        <span
          :if={@_state == :called and is_nil(@_approval_decision)}
          class="text-seafoam-500/50 shrink-0 text-[10px]"
        >
          called
        </span>
        <span :if={@_state == :pending} class="flex items-center gap-1 text-seafoam-600 shrink-0">
          <span class="w-1.5 h-1.5 rounded-full bg-seafoam-600 animate-pulse inline-block"></span>
          <span class="text-[10px]">running</span>
        </span>
        <span
          :if={@_state == :success and is_nil(@_approval_decision)}
          class="text-emerald-500 shrink-0 text-[10px]"
        >
          done
        </span>
        <span :if={@_state == :error} class="text-red-500 shrink-0 text-[10px]">error</span>
      </div>
      <div id={"#{@_id}-body"} class="hidden">
        <.tool_message_body
          name={@_name}
          arguments={@_arguments}
          approval_decision={@_approval_decision}
          approval_justification={@_approval_justification}
          reasoning_content={@_reasoning_content}
          result_content={@_result_content}
          is_cmd={@_is_cmd}
          cmd_atom={@_cmd_atom}
          cmd_body={@_cmd_body}
          state={@_state}
          error={@_error}
        />
      </div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :arguments, :any, default: nil
  attr :approval_decision, :string, default: nil
  attr :approval_justification, :string, default: nil
  attr :reasoning_content, :string, default: nil
  attr :result_content, :string, default: nil
  attr :is_cmd, :boolean, default: false
  attr :cmd_atom, :string, default: nil
  attr :cmd_body, :string, default: nil
  attr :state, :atom, required: true
  attr :error, :string, default: nil

  defp tool_message_body(assigns) do
    ~H"""
    <%= if @reasoning_content && @reasoning_content != "" do %>
      <div class="px-3 py-2 border-b border-seafoam-900/40">
        <div class="text-seafoam-600 mb-1 uppercase tracking-wider text-[10px]">reasoning</div>
        <pre class="text-seafoam-400/70 whitespace-pre-wrap break-all text-[11px] leading-relaxed">{@reasoning_content}</pre>
      </div>
    <% end %>
    <.tool_call_args_section name={@name} arguments={@arguments} />
    <%= if @approval_decision do %>
      <div class="px-3 py-2 border-t border-seafoam-900/40">
        <div class="text-seafoam-600 mb-1 uppercase tracking-wider text-[10px]">reason</div>
        <p class="text-seafoam-400/80 whitespace-pre-wrap break-all">
          {if @approval_justification && @approval_justification != "",
            do: @approval_justification,
            else: "—"}
        </p>
      </div>
    <% end %>
    <%= if @result_content do %>
      <div class="px-3 py-2 border-t border-seafoam-900/40">
        <div class="text-seafoam-700 mb-1 uppercase tracking-wider text-[10px]">result</div>
        <%= if @is_cmd do %>
          <span class={[
            "font-bold",
            if(@cmd_atom == "ok", do: "text-green-500", else: "text-red-400")
          ]}>
            {":" <> @cmd_atom}
          </span>
          <pre class="text-seafoam-500/70 whitespace-pre-wrap break-all mt-1">{@cmd_body}</pre>
        <% else %>
          <pre class="text-emerald-300/80 whitespace-pre-wrap break-all">{@result_content}</pre>
        <% end %>
      </div>
    <% end %>
    <div :if={@state == :error} class="px-3 py-2 border-t border-red-900/30 bg-red-950/20">
      <div class="text-red-700 mb-1 uppercase tracking-wider text-[10px]">error</div>
      <pre class="text-red-400 whitespace-pre-wrap break-all">{@error}</pre>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Message grouping
  # ---------------------------------------------------------------------------

  @doc """
  Groups a flat messages list into display items, pairing each assistant
  tool-call message with its immediately following tool-result messages.

  Returns a list of:
    - `{:plain, msg}`                      — a user or text-only assistant message
    - `{:tool_exchange, tool_call, result}` — paired call + result (result may be nil)
  """
  def group_messages(messages), do: do_group(messages, [])

  defp do_group([], acc), do: Enum.reverse(acc)

  defp do_group([%{role: :assistant} = msg | rest], acc) do
    tool_calls = Map.get(msg, :tool_calls) || []

    if tool_calls != [] do
      call_id_map = Map.new(tool_calls, fn tc -> {tc.id, true} end)
      {results, remaining} = take_tool_results(rest, call_id_map, [])
      results_by_id = Map.new(results, fn r -> {r.tool_call_id, r} end)

      reasoning = Map.get(msg, :reasoning_content)

      exchanges =
        Enum.map(tool_calls, fn tc ->
          tc =
            if reasoning && reasoning != "",
              do: Map.put(tc, :reasoning_content, reasoning),
              else: tc

          {:tool_exchange, tc, Map.get(results_by_id, tc.id)}
        end)

      text_items =
        if msg.content && msg.content != "",
          do: [{:plain, %{msg | tool_calls: []}}],
          else: []

      do_group(remaining, Enum.reverse(text_items ++ exchanges) ++ acc)
    else
      do_group(rest, [{:plain, msg} | acc])
    end
  end

  defp do_group([msg | rest], acc), do: do_group(rest, [{:plain, msg} | acc])

  defp take_tool_results(msgs, ids, acc) when ids == %{}, do: {Enum.reverse(acc), msgs}
  defp take_tool_results([], _ids, acc), do: {Enum.reverse(acc), []}

  defp take_tool_results([%{role: :tool, tool_call_id: tid} = msg | rest], ids, acc) do
    if Map.has_key?(ids, tid) do
      take_tool_results(rest, Map.delete(ids, tid), [msg | acc])
    else
      {Enum.reverse(acc), [msg | rest]}
    end
  end

  defp take_tool_results(remaining, _ids, acc), do: {Enum.reverse(acc), remaining}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  attr :name, :string, default: nil
  attr :arguments, :any, default: nil

  defp tool_call_args_section(%{name: "run_command", arguments: args} = assigns)
       when not is_nil(args) and args != "" do
    assigns = assign(assigns, :_command, extract_command(args))

    ~H"""
    <div class="px-3 py-2">
      <%= if @_command do %>
        <div class="text-seafoam-500 mb-1 uppercase tracking-wider text-[10px]">command</div>
        <pre class="text-seafoam-300 whitespace-pre-wrap break-all"><code>{@_command}</code></pre>
      <% else %>
        <div class="text-seafoam-500 mb-1 uppercase tracking-wider text-[10px]">arguments</div>
        <.json_display json={@arguments} />
      <% end %>
    </div>
    """
  end

  defp tool_call_args_section(%{arguments: args} = assigns)
       when not is_nil(args) and args != "" do
    ~H"""
    <div class="px-3 py-2">
      <div class="text-seafoam-500 mb-1 uppercase tracking-wider text-[10px]">arguments</div>
      <.json_display json={@arguments} />
    </div>
    """
  end

  defp tool_call_args_section(assigns), do: ~H""

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

  defp parse_command_result(nil), do: {false, nil, nil}
  defp parse_command_result(""), do: {false, nil, nil}

  defp parse_command_result(content) do
    case Regex.run(@tool_output_tuple_pattern, content) do
      [_, atom, inner] -> {true, atom, unescape_string(inner)}
      _ -> {false, nil, nil}
    end
  end

  defp unescape_string(s) do
    Regex.replace(@string_unescape_pattern, s, fn
      _, "n" -> "\n"
      _, "t" -> "\t"
      _, "r" -> "\r"
      _, "\\" -> "\\"
      _, "\"" -> "\""
    end)
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

  defp extract_command(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{"command" => cmd}} when is_binary(cmd) -> cmd
      _ -> nil
    end
  end

  defp extract_command(%{"command" => cmd}) when is_binary(cmd), do: cmd
  defp extract_command(_), do: nil
end
