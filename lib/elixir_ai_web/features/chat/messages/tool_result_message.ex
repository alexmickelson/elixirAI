defmodule ElixirAiWeb.ToolResultMessage do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  defp max_width_class, do: "max-w-full xl:max-w-300"

  defp parse_command_result(nil), do: :raw
  defp parse_command_result(""), do: :raw

  defp parse_command_result(content) do
    case Regex.run(~r/^\{:([a-z][a-z0-9_]*),\s*"(.*)"\}$/s, content) do
      [_, atom, inner] -> {:command, atom, unescape_string(inner)}
      _ -> :raw
    end
  end

  defp unescape_string(s) do
    Regex.replace(~r/\\(n|t|r|\\|")/, s, fn
      _, "n" -> "\n"
      _, "t" -> "\t"
      _, "r" -> "\r"
      _, "\\" -> "\\"
      _, "\"" -> "\""
    end)
  end

  attr :content, :string, required: true
  attr :tool_call_id, :string, required: true

  def tool_result_message(assigns) do
    id = "tr-#{:erlang.phash2(assigns.tool_call_id)}"

    truncated =
      case assigns.content do
        nil ->
          nil

        "" ->
          nil

        c ->
          first_line = c |> String.split("\n", parts: 2) |> hd() |> String.trim()

          if String.length(first_line) > 80,
            do: String.slice(first_line, 0, 77) <> "\u2026",
            else: first_line
      end

    {is_command, command_atom, command_body} =
      case parse_command_result(assigns.content) do
        {:command, atom, inner} -> {true, atom, inner}
        :raw -> {false, nil, nil}
      end

    assigns =
      assigns
      |> assign(:_id, id)
      |> assign(:_truncated, truncated)
      |> assign(:_is_command, is_command)
      |> assign(:_command_atom, command_atom)
      |> assign(:_command_body, command_body)

    ~H"""
    <div class={"mb-1 #{max_width_class()} rounded-lg border border-seafoam-900/40 bg-seafoam-950/20 text-xs font-mono overflow-hidden"}>
      <div
        class="flex items-center gap-2 px-3 py-1.5 border-b border-seafoam-900/40 bg-seafoam-900/10 text-seafoam-600 cursor-pointer select-none"
        phx-click={
          JS.toggle_class("hidden", to: "##{@_id}-body")
          |> JS.toggle_class("rotate-180", to: "##{@_id}-chevron")
        }
      >
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
        <span class="text-seafoam-600/70 shrink-0">tool result</span>
        <span :if={@_truncated} class="text-seafoam-500/50 truncate flex-1 min-w-0 ml-1">
          {@_truncated}
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
        <span class="text-seafoam-800 text-[10px] truncate max-w-[12rem]">{@tool_call_id}</span>
      </div>
      <div id={"#{@_id}-body"} class="hidden px-3 py-2">
        <pre :if={!@_is_command} class="text-seafoam-500/70 whitespace-pre-wrap break-all">{@content}</pre>
        <div :if={@_is_command}>
          <span class={[
            "font-bold",
            if(@_command_atom == "ok", do: "text-green-500", else: "text-red-400")
          ]}>
            {":" <> @_command_atom}
          </span>
          <pre class="text-seafoam-500/70 whitespace-pre-wrap break-all mt-1">{@_command_body}</pre>
        </div>
      </div>
    </div>
    """
  end
end
