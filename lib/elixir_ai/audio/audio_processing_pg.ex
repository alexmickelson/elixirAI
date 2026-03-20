defmodule ElixirAi.AudioProcessingPG do
  @moduledoc """
  Named :pg scope for tracking audio transcription workers across the cluster.

  Workers join two groups:
    - :all       — always a member while alive (used for pool-size accounting)
    - :available — member only while idle (used for dispatch; left while processing)

  :pg automatically removes dead processes, so no manual cleanup is needed.
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
