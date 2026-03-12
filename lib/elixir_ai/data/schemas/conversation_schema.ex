defmodule ElixirAi.Data.ConversationSchema do
  defstruct [:id, :name, :ai_provider_id, :inserted_at, :updated_at]

  def schema do
    Zoi.object(%{
      id: Zoi.string(),
      name: Zoi.string(),
      ai_provider_id: Zoi.string()
    })
  end
end
