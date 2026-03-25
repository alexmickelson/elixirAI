defmodule ElixirAi.PageToolsPG do
  @moduledoc """
  Named :pg scope for tracking LiveViews that implement AiControllable.
  Group key is `{:page, voice_session_id}` — one group per browser session.
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
