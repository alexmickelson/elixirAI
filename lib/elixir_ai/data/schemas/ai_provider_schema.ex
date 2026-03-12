defmodule ElixirAi.Data.AiProviderSchema do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ai_providers" do
    field(:name, :string)
    field(:model_name, :string)
    field(:api_token, :string)
    field(:completions_url, :string)

    timestamps(type: :utc_datetime)
  end
end
