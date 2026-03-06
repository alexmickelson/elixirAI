defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirAiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elixir_ai, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirAi.PubSub},
      ElixirAi.ToolTesting,
      ElixirAiWeb.Endpoint,
      {Registry, keys: :unique, name: ElixirAi.ChatRegistry},
      {DynamicSupervisor, name: ElixirAi.ChatRunnerSupervisor, strategy: :one_for_one},
      ElixirAi.ConversationManager
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
