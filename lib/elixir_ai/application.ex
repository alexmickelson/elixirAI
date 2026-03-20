defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirAiWeb.Telemetry,
      # Conditionally start Repo (skip in test environment)
      repo_child_spec(),
      default_provider_task(),
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: ElixirAi.ClusterSupervisor]]},
      {Phoenix.PubSub, name: ElixirAi.PubSub},
      {ElixirAi.LiveViewPG, []},
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
      cluster_singleton_child_spec()
    ]

    opts = [strategy: :one_for_one, name: ElixirAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ElixirAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Skip Repo and related tasks in test environment
  defp repo_child_spec do
    if Application.get_env(:elixir_ai, :env) == :test do
      Supervisor.child_spec({Task, fn -> :ok end}, id: :skip_repo)
    else
      ElixirAi.Repo
    end
  end

  defp default_provider_task do
    if Application.get_env(:elixir_ai, :env) == :test do
      Supervisor.child_spec({Task, fn -> :ok end}, id: :skip_default_provider)
    else
      {Task, fn -> ElixirAi.AiProvider.ensure_configured_providers() end}
    end
  end

  defp cluster_singleton_child_spec do
    if Application.get_env(:elixir_ai, :env) == :test do
      Supervisor.child_spec({Task, fn -> :ok end}, id: :skip_cluster_singleton)
    else
      ElixirAi.ClusterSingleton
    end
  end
end
