defmodule ElixirAiCommandTool.Runner.CommandExecutor do
  @moduledoc """
  Executes system commands and returns truncated {stdout, stderr, exit_code}.

  This module wraps `System.cmd/3` with error handling for unknown commands
  and unexpected exceptions.
  """

  alias ElixirAiCommandTool.Runner.Truncator

  # Real system PATH without /app/shims to prevent recursive shim invocation.
  # When commands are executed via the BEAM daemon (HTTP or socket), child
  # processes must resolve to real binaries, not back to shims.
  @clean_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  @doc """
  Execute a command with the given arguments.

  Returns `{stdout, stderr, exit_code}` where output has been truncated
  according to the configured limits. Stderr is merged into stdout so the
  agent always sees error messages (per the principle: never drop stderr).
  """
  def execute(command, args) when is_binary(command) and is_list(args) do
    case find_real_executable(command) do
      nil ->
        {"", "command not found: #{command}", 127}

      executable ->
        try do
          {output, exit_code} =
            System.cmd(executable, args,
              stderr_to_stdout: true,
              env: [{"PATH", @clean_path}]
            )

          {Truncator.truncate(output), "", exit_code}
        rescue
          e ->
            {"", Exception.message(e), 1}
        end
    end
  end

  # Find the executable using the clean PATH (skipping /app/shims)
  defp find_real_executable(command) do
    @clean_path
    |> String.split(":")
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, command)
      if File.exists?(path) and not File.dir?(path), do: path
    end)
  end
end
