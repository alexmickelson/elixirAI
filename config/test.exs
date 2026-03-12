import Config

# Mark this as test environment
config :elixir_ai, :env, :test

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elixir_ai, ElixirAiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "S9kKgFJCSrYQxw8sxMcglkeNqNb8dXwFn7MHNaH6ti+gKGzZkDMq4DKObWCUVw5W",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Configure the database for testing
# We use pool_size: 0 to prevent database connections during tests
config :elixir_ai, ElixirAi.Repo, pool_size: 0
