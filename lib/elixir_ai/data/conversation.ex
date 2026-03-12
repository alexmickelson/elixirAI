defmodule ElixirAi.Conversation do
  import Ecto.Query
  alias ElixirAi.Repo
  alias ElixirAi.Data.ConversationSchema
  alias ElixirAi.Data.AiProviderSchema
  require Logger

  defmodule Provider do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:name, :string)
      field(:model_name, :string)
      field(:api_token, :string)
      field(:completions_url, :string)
    end

    def changeset(provider, attrs) do
      provider
      |> cast(attrs, [:name, :model_name, :api_token, :completions_url])
      |> validate_required([:name, :model_name, :api_token, :completions_url])
    end
  end

  defmodule ConversationInfo do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:name, :string)
      embeds_one(:provider, Provider)
    end

    def changeset(conversation, attrs) do
      conversation
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> cast_embed(:provider, with: &Provider.changeset/2, required: true)
    end
  end

  def all_names do
    results =
      Repo.all(
        from(c in ConversationSchema,
          left_join: p in AiProviderSchema,
          on: c.ai_provider_id == p.id,
          select: %{
            name: c.name,
            provider: %{
              name: p.name,
              model_name: p.model_name,
              api_token: p.api_token,
              completions_url: p.completions_url
            }
          }
        )
      )

    Enum.map(results, fn attrs ->
      changeset = ConversationInfo.changeset(%ConversationInfo{}, attrs)

      if changeset.valid? do
        Ecto.Changeset.apply_changes(changeset)
      else
        Logger.error("Invalid conversation data: #{inspect(changeset.errors)}")
        raise ArgumentError, "Invalid conversation data: #{inspect(changeset.errors)}"
      end
    end)
  end

  def create(name, ai_provider_id) when is_binary(ai_provider_id) do
    # Convert string UUID from frontend to binary UUID for database
    case Ecto.UUID.dump(ai_provider_id) do
      {:ok, binary_id} ->
        Repo.insert_all("conversations", [
          [name: name, ai_provider_id: binary_id, inserted_at: now(), updated_at: now()]
        ])
        |> case do
          {1, _} -> :ok
          _ -> {:error, :db_error}
        end

      :error ->
        {:error, :invalid_uuid}
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "conversations_name_index",
        do: {:error, :already_exists},
        else: {:error, :db_error}
  end

  def find_id(name) do
    case Repo.one(from(c in ConversationSchema, where: c.name == ^name, select: c.id)) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
