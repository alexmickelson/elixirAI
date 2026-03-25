defmodule ElixirAi.SingletonPG do
  @moduledoc """
  Named :pg scope for tracking cluster singleton processes across the cluster.
  Each singleton joins {:singleton, __MODULE__} on init; :pg syncs membership
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
