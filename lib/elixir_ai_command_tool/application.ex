defmodule ElixirAiCommandTool.Application do
  @moduledoc """
  Supervisor for the command tool runner.

  Supervises:
  - Bandit HTTP server (external API on configurable port)
  - SocketServer (internal Unix socket for shims)
  """

  use Supervisor
  require Logger

  @default_port 4001

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    port = get_port()
    Logger.info("CommandTool starting on port #{port}")

    children = [
      {Bandit, plug: ElixirAiCommandTool.Http.Router, port: port, scheme: :http},
      ElixirAiCommandTool.Runner.SocketServer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp get_port do
    case System.get_env("COMMAND_TOOL_PORT") do
      nil -> @default_port
      port_str -> String.to_integer(port_str)
    end
  end
end
