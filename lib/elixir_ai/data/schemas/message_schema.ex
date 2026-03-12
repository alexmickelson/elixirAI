defmodule ElixirAi.Data.MessageSchema do
  defstruct [
    :id,
    :conversation_id,
    :role,
    :content,
    :reasoning_content,
    :tool_calls,
    :tool_call_id,
    :inserted_at
  ]

  def schema do
    Zoi.object(%{
      role: Zoi.string()
    })
  end
end
