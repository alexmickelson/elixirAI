defmodule ElixirAi.AiControllable.Hook do
  @moduledoc """
  LiveView on_mount hook that registers a page LiveView in the
  `:ai_page_tools` pg group so VoiceLive can discover it.

  The group key is `{:page, voice_session_id}` where `voice_session_id`
  comes from the Plug session, tying the page LiveView to the same browser
  tab as VoiceLive.

  Only joins when the LiveView module implements `ai_tools/0`
  (i.e. uses `ElixirAi.AiControllable`).
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    voice_session_id = session["voice_session_id"]
    module = socket.view

    if voice_session_id && function_exported?(module, :ai_tools, 0) do
      if connected?(socket) do
        try do
          :pg.join(ElixirAi.PageToolsPG, {:page, voice_session_id}, self())
        catch
          :exit, _ -> :ok
        end
      end

      {:cont, assign(socket, :voice_session_id, voice_session_id)}
    else
      {:cont, socket}
    end
  end
end
