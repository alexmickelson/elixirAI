defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirAiWeb.Telemetry,
      ElixirAi.Repo,
      {Task, fn -> ElixirAi.AiProvider.ensure_default_provider() end},
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
end
