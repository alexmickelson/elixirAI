defmodule ElixirAiWeb.JsonDisplay do
  use Phoenix.Component

  attr :json, :any, required: true
  attr :class, :string, default: nil
  attr :inline, :boolean, default: false

  def json_display(%{json: json, inline: inline} = assigns) do
    formatted =
      case json do
        nil ->
          ""

        "" ->
          ""

        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, decoded} -> Jason.encode!(decoded, pretty: !inline)
            _ -> s
          end

        other ->
          Jason.encode!(other, pretty: !inline)
      end

    assigns = assign(assigns, :_highlighted, json_to_html(formatted))

    ~H"""
    <pre
      :if={!@inline}
      class={["whitespace-pre-wrap break-all text-xs font-mono leading-relaxed", @class]}
    ><%= @_highlighted %></pre>
    <span :if={@inline} class={["text-xs font-mono truncate", @class]}>{@_highlighted}</span>
    """
  end

  @token_colors %{
    key: "text-sky-300",
    string: "text-emerald-400/80",
    keyword: "text-violet-400",
    number: "text-orange-300/80",
    colon: "text-seafoam-500/50",
    punctuation: "text-seafoam-500/50",
    quote: "text-seafoam-500/50"
  }

  # Converts a plain JSON string into a Phoenix.HTML.safe value with
  # <span> tokens coloured by token type.
  defp json_to_html(""), do: Phoenix.HTML.raw("")

  defp json_to_html(str) do
    # Capture groups (in order):
    # 1  string literal       "..."
    # 2  keyword              true | false | null
    # 3  number               -?digits with optional frac/exp
    # 4  punctuation          { } [ ] , :
    # 5  whitespace           spaces / newlines / tabs
    # 6  fallback             any other single char
    token_re =
      ~r/(".(?:[^"\\]|\\.)*")|(true|false|null)|(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)|([{}\[\],:])|(\s+)|(.)/s

    tokens = Regex.scan(token_re, str, capture: :all_but_first)

    {parts, _, _} =
      Enum.reduce(tokens, {[], :val, []}, fn groups, {acc, state, ctx} ->
        [string_tok, keyword_tok, number_tok, punct_tok, whitespace_tok, fallback_tok] =
          pad_groups(groups, 6)

        cond do
          string_tok != "" ->
            {color, next_state} =
              if state == :key,
                do: {@token_colors.key, :after_key},
                else: {@token_colors.string, :after_val}

            content = string_tok |> String.slice(1..-2//1) |> html_escape()
            quote_span = color_span(@token_colors.quote, "&quot;")

            {[quote_span <> color_span(color, content) <> quote_span | acc], next_state, ctx}

          keyword_tok != "" ->
            {[color_span(@token_colors.keyword, keyword_tok) | acc], :after_val, ctx}

          number_tok != "" ->
            {[color_span(@token_colors.number, number_tok) | acc], :after_val, ctx}

          punct_tok != "" ->
            {next_state, next_ctx} = advance_state(punct_tok, state, ctx)
            color = if punct_tok == ":", do: @token_colors.colon, else: @token_colors.punctuation
            {[color_span(color, punct_tok) | acc], next_state, next_ctx}

          whitespace_tok != "" ->
            {[whitespace_tok | acc], state, ctx}

          fallback_tok != "" ->
            {[html_escape(fallback_tok) | acc], state, ctx}

          true ->
            {acc, state, ctx}
        end
      end)

    Phoenix.HTML.raw(parts |> Enum.reverse() |> Enum.join())
  end

  # State transitions driven by punctuation tokens.
  # State :key   → we are about to read an object key.
  # State :val   → we are about to read a value.
  # State :after_key / :after_val → consumed the token; awaiting : or ,.
  defp advance_state("{", _, ctx), do: {:key, [:obj | ctx]}
  defp advance_state("[", _, ctx), do: {:val, [:arr | ctx]}
  defp advance_state("}", _, [_ | ctx]), do: {:after_val, ctx}
  defp advance_state("}", _, []), do: {:after_val, []}
  defp advance_state("]", _, [_ | ctx]), do: {:after_val, ctx}
  defp advance_state("]", _, []), do: {:after_val, []}
  defp advance_state(":", _, ctx), do: {:val, ctx}
  defp advance_state(",", _, [:obj | _] = ctx), do: {:key, ctx}
  defp advance_state(",", _, ctx), do: {:val, ctx}
  defp advance_state(_, state, ctx), do: {state, ctx}

  defp pad_groups(list, n), do: list ++ List.duplicate("", max(0, n - length(list)))

  defp color_span(class, content), do: ~s|<span class="#{class}">#{content}</span>|

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
