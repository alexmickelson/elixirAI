defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Attach custom logger that filters health checks
    :telemetry.attach(
      "phoenix-endpoint-logger",
      [:phoenix, :endpoint, :stop],
      &__MODULE__.log_request/4,
      %{}
    )

    children = [
      ElixirAiWeb.Telemetry,
      ElixirAi.Repo,
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: ElixirAi.ClusterSupervisor]]},
      {Phoenix.PubSub, name: ElixirAi.PubSub},
      ElixirAi.ToolTesting,
      ElixirAiWeb.Endpoint,
      {Horde.Registry,
       [
         name: ElixirAi.ChatRegistry,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: 100]
       ]},
      {Horde.DynamicSupervisor,
       [
         name: ElixirAi.ChatRunnerSupervisor,
         strategy: :one_for_one,
         members: :auto,
         delta_crdt_options: [sync_interval: 100],
         process_redistribution: :active
       ]},
      ElixirAi.ClusterSingleton
    ]

    opts = [strategy: :one_for_one, name: ElixirAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElixirAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Custom request logger that filters health check endpoint
  require Logger

  def log_request(_event, measurements, %{conn: conn}, _config) do
    # Skip logging for health check endpoint
    if conn.request_path != "/health" do
      duration = System.convert_time_unit(measurements.duration, :native, :microsecond)

      Logger.info(
        fn ->
          [conn.method, " ", conn.request_path]
        end,
        request_id: conn.assigns[:request_id]
      )

      Logger.info(
        fn ->
          ["Sent ", to_string(conn.status), " in ", format_duration(duration)]
        end,
        request_id: conn.assigns[:request_id]
      )
    end
  end

  defp format_duration(μs) when μs < 1000, do: "#{μs}µs"
  defp format_duration(μs) when μs < 1_000_000, do: "#{div(μs, 1000)}ms"
  defp format_duration(μs), do: "#{Float.round(μs / 1_000_000, 2)}s"
end
