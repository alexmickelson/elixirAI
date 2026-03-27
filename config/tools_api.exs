import Config

# Minimal config for the tools_api environment (command tool runner container).
# Disables Phoenix endpoint, Ecto, clustering, asset watchers — only the
# command tool HTTP server and socket server run.

config :elixir_ai,
  env: :tools_api,
  ecto_repos: []

# Disable the Phoenix endpoint (not needed in the runner)
config :elixir_ai, ElixirAiWeb.Endpoint, server: false

# Logger
config :logger, level: :info
