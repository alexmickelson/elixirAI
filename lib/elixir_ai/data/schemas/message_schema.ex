defmodule ElixirAi.Data.MessageSchema do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "messages" do
    belongs_to(:conversation, ElixirAi.Data.ConversationSchema, type: :binary_id)
    field(:role, :string)
    field(:content, :string)
    field(:reasoning_content, :string)
    field(:tool_calls, :map)
    field(:tool_call_id, :string)

    timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime)
  end
end
