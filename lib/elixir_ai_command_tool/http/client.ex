defmodule ElixirAiCommandTool.Http.Client do
  @moduledoc """
  HTTP client for sending commands to the command tool runner container.

  Used by the main ElixirAI application to execute commands on behalf of the AI.
  Sends HTTP POST requests to the runner's `/api/execute` endpoint and formats
  the responses for consumption by the AI conversation.

  The runner URL is configured via the `COMMAND_TOOL_URL` environment variable
  (read into `Application.get_env(:elixir_ai, :command_tool_url)`).
  """

  require Logger

  @timeout 30_000

  @doc """
  Execute a command on the runner and return `{:ok, %{stdout, stderr, exit_code}}`
  or `{:error, reason}`.
  """
  def execute(command, args \\ []) when is_binary(command) and is_list(args) do
    with {:ok, url} <- fetch_url() do
      body = Jason.encode!(%{"command" => command, "args" => args})

      Logger.info("CommandTool executing: #{command} #{Enum.join(args, " ")}")

      case Req.post(url <> "/api/execute",
             body: body,
             headers: [{"content-type", "application/json"}],
             receive_timeout: @timeout
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          result = %{
            stdout: body["stdout"],
            stderr: body["stderr"],
            exit_code: body["exit_code"]
          }

          Logger.info("CommandTool completed: exit_code=#{result.exit_code}")
          {:ok, result}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("CommandTool runner returned #{status}: #{inspect(body)}")
          {:error, "runner returned status #{status}: #{inspect(body)}"}

        {:error, exception} ->
          Logger.error("CommandTool request failed: #{Exception.message(exception)}")
          {:error, "runner request failed: #{Exception.message(exception)}"}
      end
    end
  end

  @doc """
  Execute a full shell command string via `bash -c`.
  Useful for piped commands, redirects, and chaining.
  """
  def run_bash(shell_command) when is_binary(shell_command) do
    execute("bash", ["-c", shell_command])
  end

  @doc """
  Format an execution result into a string suitable for returning to the AI.
  Includes stdout, stderr (if present), and exit code (if non-zero).
  """
  def format_result(%{stdout: stdout, stderr: stderr, exit_code: exit_code}) do
    parts = []

    parts =
      if stdout != "" do
        parts ++ [stdout]
      else
        parts
      end

    parts =
      if stderr != "" do
        parts ++ ["STDERR: #{stderr}"]
      else
        parts
      end

    parts =
      if exit_code != 0 do
        parts ++ ["Exit code: #{exit_code}"]
      else
        parts
      end

    case parts do
      [] -> "(no output)"
      _ -> Enum.join(parts, "\n")
    end
  end

  @doc """
  Check if the command runner is reachable.
  Returns `:ok` or `{:error, reason}`.
  """
  def health_check do
    case execute("echo", ["ok"]) do
      {:ok, %{stdout: stdout, exit_code: 0}} ->
        if String.contains?(stdout, "ok"), do: :ok, else: {:error, "unexpected output"}

      {:ok, %{exit_code: code}} ->
        {:error, "health check returned exit code #{code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_url do
    case Application.get_env(:elixir_ai, :command_tool_url) do
      nil -> {:error, "COMMAND_TOOL_URL not configured"}
      url -> {:ok, url}
    end
  end
end
