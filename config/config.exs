# General config, overriden by other files in this directory.
import Config

config :elixir_ai,
  ecto_repos: [ElixirAi.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elixir_ai, ElixirAiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ElixirAiWeb.ErrorHTML, json: ElixirAiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ElixirAi.PubSub,
  live_view: [signing_salt: "4UG1IVt+"]

config :esbuild,
  version: "0.17.11",
  elixir_ai: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.0.9",
  elixir_ai: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
config :postgrex, :json_library, Jason

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

import_config "#{config_env()}.exs"
