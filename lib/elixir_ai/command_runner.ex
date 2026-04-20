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
  Execute a shell command and stream output lines to `caller` as they arrive.

  Sends to `caller`:
    `{:cmd_chunk, tool_call_id, line}` — for each line of combined stdout/stderr
    `{:cmd_done,  tool_call_id, exit_code, duration_ms}` — when the process exits

  Uses a Port so the GenServer mailbox is not blocked.
  """
  def run_bash_stream(shell_command, tool_call_id, caller) when is_binary(shell_command) do
    container = container_name()

    wrapped =
      "{\n#{shell_command}\n} 2>&1"

    docker_args = ["exec", container, "bash", "-c", wrapped]

    Logger.info("CommandRunner (stream): #{container} $ #{shell_command}")

    start_time = System.monotonic_time(:millisecond)

    port =
      Port.open({:spawn_executable, System.find_executable("docker")}, [
        {:args, docker_args},
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4096}
      ])

    stream_loop(port, tool_call_id, caller, start_time, "")
  end

  defp stream_loop(port, tool_call_id, caller, start_time, buffer) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = buffer <> line
        send(caller, {:cmd_chunk, tool_call_id, full_line <> "\n"})
        stream_loop(port, tool_call_id, caller, start_time, "")

      {^port, {:data, {:noeol, partial}}} ->
        stream_loop(port, tool_call_id, caller, start_time, buffer <> partial)

      {^port, {:exit_status, code}} ->
        # flush any remaining buffered partial line
        unless buffer == "", do: send(caller, {:cmd_chunk, tool_call_id, buffer})
        duration_ms = System.monotonic_time(:millisecond) - start_time
        send(caller, {:cmd_done, tool_call_id, code, duration_ms})
    after
      300_000 ->
        Port.close(port)
        duration_ms = System.monotonic_time(:millisecond) - start_time
        send(caller, {:cmd_chunk, tool_call_id, "\n[timed out after 5 minutes]\n"})
        send(caller, {:cmd_done, tool_call_id, 1, duration_ms})
    end
  end

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
    Application.get_env(:elixir_ai, :sandbox_container) || "llm_sandbox"
  end
end
