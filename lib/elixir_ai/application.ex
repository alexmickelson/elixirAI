defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = full_children()

    opts = [strategy: :one_for_one, name: ElixirAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp full_children do
    [
      ElixirAiWeb.Telemetry,
      repo_child_spec(),
      default_provider_task(),
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []), [name: ElixirAi.ClusterSupervisor]]},
      {Phoenix.PubSub, name: ElixirAi.PubSub},
      {ElixirAi.LiveViewPG, []},
      {ElixirAi.RunnerPG, []},
      {ElixirAi.SingletonPG, []},
      {ElixirAi.PageToolsPG, []},
      {ElixirAi.AudioProcessingPG, []},
      {DynamicSupervisor, name: ElixirAi.AudioWorkerSupervisor, strategy: :one_for_one},
      ElixirAi.ToolTesting,
      ElixirAiWeb.Endpoint,
      {Registry, keys: :unique, name: ElixirAi.McpRegistry},
      {DynamicSupervisor, name: ElixirAi.Mcp.McpClientSupervisor, strategy: :one_for_one},
      mcp_server_manager_child_spec(),
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
      cluster_singleton_child_spec(ElixirAi.ConversationManager)
    ]
  end

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

  defp cluster_singleton_child_spec(module) do
    if Application.get_env(:elixir_ai, :env) == :test do
      Supervisor.child_spec({Task, fn -> :ok end}, id: {:skip_cluster_singleton, module})
    else
      {ElixirAi.ClusterSingletonLauncher, module: module}
    end
  end

  defp mcp_server_manager_child_spec do
    if Application.get_env(:elixir_ai, :env) == :test do
      Supervisor.child_spec({Task, fn -> :ok end}, id: :skip_mcp_server_manager)
    else
      ElixirAi.Mcp.McpServerManager
    end
  end
end
