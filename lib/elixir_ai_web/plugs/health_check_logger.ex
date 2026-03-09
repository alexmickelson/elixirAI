defmodule ElixirAiWeb.Plugs.HealthCheckLogger do
  @moduledoc """
  Plug that marks health check requests for filtering.
  """
  @behaviour Plug
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["health"]} = conn, _opts) do
    # Mark this as a health check for logger filtering
    Logger.metadata(health_check: true)
    conn
  end

  def call(conn, _opts), do: conn
end
