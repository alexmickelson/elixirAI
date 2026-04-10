defmodule ElixirAi.RunnerPG do
  @moduledoc """
  Named :pg scope for tracking ChatRunner processes across the cluster.
  Each ChatRunner joins {:runner, name} on init; :pg syncs membership
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
