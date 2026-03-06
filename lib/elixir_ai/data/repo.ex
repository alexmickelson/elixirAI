defmodule ElixirAi.Repo do
  use Ecto.Repo,
    otp_app: :elixir_ai,
    adapter: Ecto.Adapters.Postgres
end
