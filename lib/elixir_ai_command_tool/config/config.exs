import Config

# Minimal config for the command tool runner container.
# Only Jason and logger are needed — no Phoenix, Ecto, or clustering.

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

config :logger, level: :info
