defmodule ElixirAi.CommandRunner do
  @moduledoc """
  Layer 1: Unix execution layer.

  Executes commands inside the sandbox container via SSH.
  Returns raw {stdout, stderr, exit_code, duration_ms} — no truncation,
  no metadata injection, no formatting. Pipes and chains work natively
  because execution goes through `bash -c`.

  All LLM-facing processing happens in CommandRunner.Presentation (Layer 2).
  """

  require Logger

  @stream_start_timeout_ms 10_000

  def run_bash_stream(shell_command, tool_call_id, caller) when is_binary(shell_command) do
    starter = self()

    task_pid =
      spawn_link(fn ->
        start_streaming_command(starter, shell_command, tool_call_id, caller)
      end)

    receive do
      {:cmd_stream_started, ^tool_call_id, :ok} ->
        {:ok, task_pid}

      {:cmd_stream_started, ^tool_call_id, {:error, reason}} ->
        message = format_runner_error(reason)
        Logger.error("CommandRunner failed to start command stream: #{message}")
        {:error, message}
    after
      @stream_start_timeout_ms ->
        Process.exit(task_pid, :kill)
        {:error, "Sandbox SSH connection failed: timed out while starting command stream"}
    end
  end

  defp start_streaming_command(starter, shell_command, tool_call_id, caller) do
    with {:ok, conn_ref} <- ElixirAi.CommandRunner.SshConnection.get(),
         {:ok, channel_id} <- open_session_channel(conn_ref),
         :ok <- exec_command(conn_ref, channel_id, shell_command) do
      send(starter, {:cmd_stream_started, tool_call_id, :ok})

      receive_loop(
        conn_ref,
        channel_id,
        tool_call_id,
        caller,
        "",
        System.monotonic_time(:millisecond)
      )
    else
      {:error, reason} ->
        send(starter, {:cmd_stream_started, tool_call_id, {:error, reason}})
    end
  end

  defp receive_loop(conn_ref, channel_id, tool_call_id, caller, buffer, start_time) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel_id, _type, data}} ->
        process_data(data, channel_id, conn_ref, tool_call_id, caller, buffer, start_time)

      {:ssh_cm, ^conn_ref, {:eof, ^channel_id}} ->
        receive_loop(conn_ref, channel_id, tool_call_id, caller, buffer, start_time)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel_id, code}} ->
        unless buffer == "",
          do: send(caller, {:cmd_chunk, tool_call_id, buffer})

        duration_ms = System.monotonic_time(:millisecond) - start_time
        send(caller, {:cmd_done, tool_call_id, code, duration_ms})

      {:ssh_cm, ^conn_ref, {:closed, ^channel_id}} ->
        Process.exit(self(), :normal)

      {:ssh_cm, ^conn_ref, {:signal, ^channel_id, _signal_name}} ->
        receive_loop(conn_ref, channel_id, tool_call_id, caller, buffer, start_time)
    after
      300_000 ->
        send(caller, {:cmd_chunk, tool_call_id, "\n[timed out after 5 minutes]\n"})

        send(
          caller,
          {:cmd_done, tool_call_id, 1, System.monotonic_time(:millisecond) - start_time}
        )
    end
  end

  defp process_data(data, channel_id, conn_ref, tool_call_id, caller, buffer, start_time) do
    lines = (buffer <> data) |> String.split("\n", keep_trailing: false)

    lines
    |> Enum.drop(-1)
    |> Enum.each(fn line ->
      send(caller, {:cmd_chunk, tool_call_id, line <> "\n"})
    end)

    new_buffer = List.last(lines) || buffer
    receive_loop(conn_ref, channel_id, tool_call_id, caller, new_buffer, start_time)
  end

  def run_bash(shell_command) when is_binary(shell_command) do
    self_ref = self()
    gen_id = System.unique_integer([:positive])
    tool_call_id = to_string(gen_id)

    case run_bash_stream(shell_command, tool_call_id, self_ref) do
      {:ok, _task_pid} -> collect_output(tool_call_id, "")
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_output(id, stdout) do
    receive do
      {:cmd_chunk, ^id, line} ->
        collect_output(id, stdout <> line)

      {:cmd_done, ^id, exit_code, duration_ms} ->
        {:ok, %{stdout: stdout, stderr: "", exit_code: exit_code, duration_ms: duration_ms}}
    after
      310_000 ->
        {:error, "blocking receive timeout"}
    end
  end

  def execute(command, args \\ []) when is_binary(command) and is_list(args) do
    full_command = Enum.join([command | args], " ")
    run_bash(full_command)
  end

  def health_check do
    case ElixirAi.CommandRunner.SshConnection.get() do
      {:ok, _conn_ref} ->
        :ok

      {:error, reason} ->
        {:error, format_runner_error(reason)}
    end
  end

  defp open_session_channel(conn_ref) do
    case :ssh_connection.session_channel(conn_ref, 60_000) do
      {:ok, channel_id} -> {:ok, channel_id}
      {:error, reason} -> {:error, {:session_channel_failed, reason}}
    end
  end

  defp exec_command(conn_ref, channel_id, shell_command) do
    case :ssh_connection.exec(conn_ref, channel_id, shell_command, 300_000) do
      :success -> :ok
      {:error, reason} -> {:error, {:exec_failed, reason}}
      other -> {:error, {:exec_failed, other}}
    end
  end

  defp format_runner_error({:session_channel_failed, reason}) do
    "Sandbox SSH connection failed while opening a session: #{format_reason(reason)}"
  end

  defp format_runner_error({:exec_failed, reason}) do
    "Sandbox SSH connection failed while starting a command: #{format_reason(reason)}"
  end

  defp format_runner_error(reason) do
    "Sandbox SSH connection failed: #{format_reason(reason)}"
  end

  defp format_reason(%{__struct__: mod, reason: inner}), do: "#{inspect(mod)}: #{inspect(inner)}"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
