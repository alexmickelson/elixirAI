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

  def run_bash_stream(shell_command, tool_call_id, caller) when is_binary(shell_command) do
    {:ok, conn_ref} = ElixirAi.CommandRunner.SshConnection.get()

    {:ok, channel_id} = :ssh_connection.session_channel(conn_ref, 60_000)

    pid = self()

    task_pid =
      spawn_link(fn ->
        receive_loop(
          conn_ref,
          channel_id,
          tool_call_id,
          caller,
          pid,
          "",
          System.monotonic_time(:millisecond)
        )
      end)

    :ssh_connection.exec(conn_ref, channel_id, shell_command, 300_000)

    task_pid
  end

  defp receive_loop(conn_ref, channel_id, tool_call_id, caller, parent, buffer, start_time) do
    receive do
      {:ssh_cm, ^conn_ref, {:data, ^channel_id, _type, data}} ->
        process_data(data, channel_id, conn_ref, tool_call_id, caller, parent, buffer, start_time)

      {:ssh_cm, ^conn_ref, {:eof, ^channel_id}} ->
        receive_loop(conn_ref, channel_id, tool_call_id, caller, parent, buffer, start_time)

      {:ssh_cm, ^conn_ref, {:exit_status, ^channel_id, code}} ->
        unless buffer == "",
          do: send(caller, {:cmd_chunk, tool_call_id, buffer})

        duration_ms = System.monotonic_time(:millisecond) - start_time
        send(caller, {:cmd_done, tool_call_id, code, duration_ms})

      {:ssh_cm, ^conn_ref, {:closed, ^channel_id}} ->
        Process.exit(self(), :normal)

      {:ssh_cm, ^conn_ref, {:signal, ^channel_id, _signal_name}} ->
        receive_loop(conn_ref, channel_id, tool_call_id, caller, parent, buffer, start_time)
    after
      300_000 ->
        send(caller, {:cmd_chunk, tool_call_id, "\n[timed out after 5 minutes]\n"})

        send(
          caller,
          {:cmd_done, tool_call_id, 1, System.monotonic_time(:millisecond) - start_time}
        )
    end
  end

  defp process_data(data, channel_id, conn_ref, tool_call_id, caller, parent, buffer, start_time) do
    lines = (buffer <> data) |> String.split("\n", keep_trailing: false)

    lines
    |> Enum.drop(-1)
    |> Enum.each(fn line ->
      send(caller, {:cmd_chunk, tool_call_id, line <> "\n"})
    end)

    new_buffer = List.last(lines) || buffer
    receive_loop(conn_ref, channel_id, tool_call_id, caller, parent, new_buffer, start_time)
  end

  def run_bash(shell_command) when is_binary(shell_command) do
    self_ref = self()
    gen_id = System.unique_integer([:positive])
    tool_call_id = to_string(gen_id)

    run_bash_stream(shell_command, tool_call_id, self_ref)
    collect_output(tool_call_id, "")
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
        {:error, "SSH connection failed: #{inspect(reason)}"}
    end
  end
end
