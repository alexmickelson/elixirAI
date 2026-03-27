defmodule ElixirAi.CommandRunner.Presentation do
  @moduledoc """
  Layer 2: LLM presentation layer.

  Transforms raw execution results into text optimized for LLM cognition.
  Implements four mechanisms:
    A. Binary guard — detect and reject binary output
    B. Overflow mode — truncate + persist full output for exploration
    C. Metadata footer — [exit:N | Xms] on every result
    D. stderr attachment — never drop error output

  This module NEVER runs during pipe execution (Layer 1). It only runs
  after the full command chain completes, on the final result.
  """

  alias ElixirAi.CommandRunner

  @max_bytes 50_000
  @max_lines 200
  @binary_control_char_threshold 0.10

  @doc """
  Format a raw execution result for the LLM.
  Applies: binary guard → overflow mode → stderr attachment → metadata footer.
  """
  def format(%{stdout: stdout, stderr: stderr, exit_code: exit_code, duration_ms: duration_ms}) do
    formatted_stdout = process_output(stdout)
    formatted_stderr = process_stderr(stderr)

    body =
      case {formatted_stdout, formatted_stderr} do
        {"", ""} -> "(no output)"
        {out, ""} -> out
        {"", err} -> err
        {out, err} -> out <> "\n" <> err
      end

    body <> "\n" <> metadata_footer(exit_code, duration_ms)
  end

  # -- Mechanism A: Binary Guard -----------------------------------------------

  defp process_output(""), do: ""

  defp process_output(output) do
    cond do
      has_null_bytes?(output) ->
        size = byte_size(output)

        "[binary data (#{format_bytes(size)}). Pipe through a text filter or use a different command]"

      not String.valid?(output) ->
        size = byte_size(output)
        "[binary data (#{format_bytes(size)}), not valid UTF-8. Use a text-based command instead]"

      high_control_char_ratio?(output) ->
        size = byte_size(output)

        "[binary data (#{format_bytes(size)}), high control character ratio. Use a text-based command instead]"

      true ->
        overflow(output)
    end
  end

  defp has_null_bytes?(data), do: :binary.match(data, <<0>>) != :nomatch

  defp high_control_char_ratio?(data) do
    total = byte_size(data)

    if total == 0 do
      false
    else
      count_control_chars(data) / total > @binary_control_char_threshold
    end
  end

  defp count_control_chars(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.count(fn byte ->
      # exclude tab, newline, carriage return
      byte < 0x20 and byte not in [0x09, 0x0A, 0x0D]
    end)
  end

  # -- Mechanism B: Overflow Mode ----------------------------------------------

  defp overflow(output) when byte_size(output) <= @max_bytes do
    truncate_lines(output)
  end

  defp overflow(output) do
    total_bytes = byte_size(output)
    total_lines = output |> String.split("\n") |> length()

    # Persist full output inside the sandbox for later exploration
    overflow_path = persist_overflow(output)

    # Truncate for LLM context
    shown = binary_part(output, 0, @max_bytes)
    truncated = truncate_lines(shown)

    truncated <>
      "\n\n--- output truncated (#{total_lines} lines, #{format_bytes(total_bytes)}) ---" <>
      overflow_navigation(overflow_path)
  end

  defp persist_overflow(output) do
    n = System.unique_integer([:positive])
    path = "/tmp/cmd-output/cmd-#{n}.txt"

    CommandRunner.run_bash(
      "mkdir -p /tmp/cmd-output && cat > #{path} <<'__OVERFLOW_EOF__'\n#{output}\n__OVERFLOW_EOF__"
    )

    path
  end

  defp overflow_navigation(path) do
    """

    Full output: #{path}
    Explore with:
      cat #{path} | grep <pattern>
      cat #{path} | tail 100
      cat #{path} | head -n 50
      wc -l #{path}
    """
  end

  defp truncate_lines(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_lines do
      Enum.take(lines, @max_lines) |> Enum.join("\n")
    else
      output
    end
  end

  # -- Mechanism C: Metadata Footer --------------------------------------------

  defp metadata_footer(exit_code, duration_ms) do
    "[exit:#{exit_code} | #{format_duration(duration_ms)}]"
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # -- Mechanism D: stderr Attachment ------------------------------------------

  defp process_stderr(""), do: ""
  defp process_stderr(stderr), do: "[stderr] " <> String.trim(stderr)

  # -- Helpers -----------------------------------------------------------------

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"
end
