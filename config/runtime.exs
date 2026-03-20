import Config
import Dotenvy

source!([".env", System.get_env()])

config :elixir_ai,
  ai_endpoint: System.get_env("AI_RESPONSES_ENDPOINT"),
  ai_token: System.get_env("AI_TOKEN"),
  ai_model: System.get_env("AI_MODEL")

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/elixir_ai start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :elixir_ai, ElixirAiWeb.Endpoint, server: true
end

# In dev mode, if DATABASE_URL is set (e.g., in Docker), use it instead of defaults
if config_env() == :dev do
  if database_url = System.get_env("DATABASE_URL") do
    config :elixir_ai, ElixirAi.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  end
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://user:password@host/database
      """

  config :elixir_ai, ElixirAi.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # In Kubernetes, switch from Gossip to DNS-based discovery via a headless service.
  # Set K8S_NAMESPACE and optionally K8S_SERVICE_NAME in your pod spec.
  if System.get_env("K8S_NAMESPACE") do
    config :libcluster,
      topologies: [
        k8s_dns: [
          strategy: Cluster.Strategy.Kubernetes.DNS,
          config: [
            service: System.get_env("K8S_SERVICE_NAME") || "ai-ha-elixir-headless",
            application_name: "elixir_ai",
            namespace: System.get_env("K8S_NAMESPACE")
          ]
        ]
      ]
  end

  host = System.get_env("PHX_HOST") || raise "environment variable PHX_HOST is missing."
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :elixir_ai, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :elixir_ai, ElixirAiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end
