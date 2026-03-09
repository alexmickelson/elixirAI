defmodule ElixirAiWeb.HealthController do
  use ElixirAiWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
