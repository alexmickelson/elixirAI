# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir_ai,
  ecto_repos: [ElixirAi.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :elixir_ai, ElixirAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElixirAiWeb.ErrorHTML, json: ElixirAiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirAi.PubSub,
  live_view: [signing_salt: "4UG1IVt+"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  elixir_ai: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.0.9",
  elixir_ai: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Lower the BEAM node-down detection window from the default 60s.
# Nodes send ticks every (net_ticktime / 4)s; a node is declared down
# after 4 missed ticks (net_ticktime total). 5s means detection in ≤5s.
if System.get_env("RELEASE_MODE") do
  config :kernel, net_ticktime: 2
end

# Libcluster — Gossip strategy works for local dev and Docker Compose
# (UDP multicast, zero config). Overridden to Kubernetes.DNS in runtime.exs for prod.
config :libcluster,
  topologies: [
    gossip: [
      strategy: Cluster.Strategy.Gossip
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
