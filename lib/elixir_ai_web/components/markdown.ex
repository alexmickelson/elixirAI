defmodule ElixirAiWeb.Markdown do
  @doc """
  Converts a markdown string to sanitized HTML, safe for raw rendering.
  Falls back to escaped plain text if the markdown is incomplete or invalid.
  """
  def render(nil), do: Phoenix.HTML.raw("")
  def render(""), do: Phoenix.HTML.raw("")

  def render(markdown) do
    case Earmark.as_html(markdown, breaks: true, compact_output: true) do
      {:ok, html, _warnings} ->
        html
        |> HtmlSanitizeEx.markdown_html()
        |> Phoenix.HTML.raw()

      {:error, html, _errors} ->
        # Partial/invalid markdown — use whatever HTML was produced, still sanitize
        html
        |> HtmlSanitizeEx.markdown_html()
        |> Phoenix.HTML.raw()
    end
  end
end
