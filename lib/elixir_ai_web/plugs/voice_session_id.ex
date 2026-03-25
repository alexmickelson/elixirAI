defmodule ElixirAiWeb.Plugs.VoiceSessionId do
  @moduledoc """
  Ensures a `voice_session_id` exists in the Plug session.

  This UUID ties VoiceLive (root layout) to page LiveViews (inner content)
  so they can discover each other via `:pg` process groups.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, "voice_session_id") do
      nil ->
        id = Ecto.UUID.generate()
        put_session(conn, "voice_session_id", id)

      _existing ->
        conn
    end
  end
end
