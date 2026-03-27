defmodule ElixirAiCommandTool.Runner.Truncator do
  @moduledoc """
  Truncates command output by bytes and lines.

  Applied in order:
  1. Truncate by bytes (@max_bytes)
  2. Truncate by lines (@max_lines)

  Appends "...[truncated]" when limits are exceeded.
  """

  @max_bytes 4000
  @max_lines 200

  @doc """
  Truncates the given binary by byte size, then by line count.
  Returns the (possibly truncated) string.
  """
  def truncate(output) when is_binary(output) do
    output
    |> truncate_bytes()
    |> truncate_lines()
  end

  defp truncate_bytes(output) when byte_size(output) > @max_bytes do
    truncated = binary_part(output, 0, @max_bytes)
    truncated <> "\n...[truncated]"
  end

  defp truncate_bytes(output), do: output

  defp truncate_lines(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_lines do
      lines
      |> Enum.take(@max_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n...[truncated]")
    else
      output
    end
  end
end
