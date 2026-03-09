defmodule ElixirAiWeb.HealthCheckFilter do
  @moduledoc """
  Logger filter to suppress health check endpoint logs.
  """

  def filter(%{meta: meta}, _config) when is_map(meta) do
    if Map.get(meta, :health_check) == true do
      :stop
    else
      :ignore
    end
  end

  def filter(_log_event, _config), do: :ignore
end
