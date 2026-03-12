defmodule ElixirAi.Data.ConversationSchema do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field(:name, :string)
    belongs_to(:ai_provider, ElixirAi.Data.AiProviderSchema, type: :binary_id)

    timestamps(type: :utc_datetime)
  end
end
