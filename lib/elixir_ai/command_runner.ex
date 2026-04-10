defmodule ElixirAi.CommandRunner do
  @moduledoc """
  Layer 1: Unix execution layer.

  Executes commands inside the sandbox container via `docker exec`.
  Returns raw {stdout, stderr, exit_code, duration_ms} — no truncation,
  no metadata injection, no formatting. Pipes and chains work natively
  because execution goes through `bash -c`.

  All LLM-facing processing happens in CommandRunner.Presentation (Layer 2).
  """

  require Logger

  @stderr_marker "__STDERR_MARKER__"

  @doc """
  Execute a shell command string via `bash -c` inside the sandbox container.

  The command string can contain pipes, chains, redirects — full bash syntax.
  Returns `{:ok, %{stdout, stderr, exit_code, duration_ms}}` or `{:error, reason}`.
  """
  def run_bash(shell_command) when is_binary(shell_command) do
    container = container_name()

    # Wrap command to capture stderr separately via temp file + marker.
    # This ensures stderr is NEVER dropped.
    # NOTE: wrapped is passed directly as a bash script argument via System.cmd
    # (no intermediate shell), so we do NOT use sh -c '...' quoting here.
    # Using sh -c with single-quote wrapping breaks commands that contain
    # single quotes, such as heredocs with quoted delimiters (<< 'EOF').
    wrapped =
      "{\n#{shell_command}\n} 2>/tmp/.cmd_stderr\n" <>
        "__exit=$?\n" <>
        "if [ -s /tmp/.cmd_stderr ]; then\n" <>
        "printf \"\\n#{@stderr_marker}\\n\"; cat /tmp/.cmd_stderr\n" <>
        "fi\n" <>
        "exit $__exit"

    docker_args = ["exec", container, "bash", "-c", wrapped]

    Logger.info("CommandRunner: #{container} $ #{shell_command}")

    start_time = System.monotonic_time(:millisecond)

    try do
      {combined, exit_code} = System.cmd("docker", docker_args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - start_time
      {stdout, stderr} = split_stderr(combined)

      {:ok, %{stdout: stdout, stderr: stderr, exit_code: exit_code, duration_ms: duration_ms}}
    rescue
      e ->
        Logger.error("CommandRunner failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Execute a raw command with arguments (no shell interpretation).
  Used for health checks and direct binary invocation.
  """
  def execute(command, args \\ []) when is_binary(command) and is_list(args) do
    container = container_name()
    docker_args = ["exec", container, command | args]

    start_time = System.monotonic_time(:millisecond)

    try do
      {output, exit_code} = System.cmd("docker", docker_args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      {:ok, %{stdout: output, stderr: "", exit_code: exit_code, duration_ms: duration_ms}}
    rescue
      e ->
        Logger.error("CommandRunner failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  def health_check do
    case execute("echo", ["ok"]) do
      {:ok, %{stdout: stdout, exit_code: 0}} ->
        if String.contains?(stdout, "ok"), do: :ok, else: {:error, "unexpected output"}

      {:ok, %{exit_code: code}} ->
        {:error, "health check exit code #{code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_stderr(combined) do
    case String.split(combined, "\n#{@stderr_marker}\n", parts: 2) do
      [stdout, stderr] -> {String.trim_trailing(stdout), String.trim_trailing(stderr)}
      [stdout] -> {stdout, ""}
    end
  end

  defp container_name do
    Application.get_env(:elixir_ai, :sandbox_container) || "command_runner"
  end
end
