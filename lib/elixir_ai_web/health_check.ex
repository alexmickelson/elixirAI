defmodule ElixirAiWeb.Plugs.HealthCheck do
  @moduledoc """
  A lightweight health check plug that responds before hitting the router.
  This avoids unnecessary processing and logging for health check requests.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts) do
    conn
    |> send_resp(200, ~s({"status":"ok"}))
    |> halt()
  end

  def call(conn, _opts), do: conn
end
