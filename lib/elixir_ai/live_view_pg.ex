defmodule ElixirAi.LiveViewPG do
  @moduledoc """
  Named :pg scope for tracking LiveView processes across the cluster.
  Each LiveView joins {:liveview, ViewModule} on connect; :pg syncs membership
  automatically and removes dead processes without any additional cleanup.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {:pg, :start_link, [__MODULE__]},
      type: :worker,
      restart: :permanent
    }
  end
end
