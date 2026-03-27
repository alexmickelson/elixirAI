import Config

# Runtime config for the command tool runner.
# Only reads the port — nothing else is needed.

config :elixir_ai,
  command_tool_port: String.to_integer(System.get_env("COMMAND_TOOL_PORT") || "4001")
