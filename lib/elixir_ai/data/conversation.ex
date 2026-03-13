defmodule ElixirAi.Conversation do
  alias ElixirAi.Data.DbHelpers
  require Logger

  defmodule Provider do
    defstruct [:name, :model_name, :api_token, :completions_url]

    def schema do
      Zoi.object(%{
        name: Zoi.string(),
        model_name: Zoi.string(),
        api_token: Zoi.string(),
        completions_url: Zoi.string()
      })
    end
  end

  defmodule ConversationInfo do
    defstruct [:name, :provider]

    def schema do
      Zoi.object(%{
        name: Zoi.string(),
        provider:
          Zoi.object(%{
            name: Zoi.string(),
            model_name: Zoi.string(),
            api_token: Zoi.string(),
            completions_url: Zoi.string()
          })
      })
    end
  end

  def all_names do
    sql = """
    SELECT c.name,
      json_build_object(
        'name', p.name,
        'model_name', p.model_name,
        'api_token', p.api_token,
        'completions_url', p.completions_url
      ) as provider
    FROM conversations c
    LEFT JOIN ai_providers p ON c.ai_provider_id = p.id
    """

    params = %{}

    case DbHelpers.run_sql(sql, params, "conversations", ConversationInfo.schema()) do
      {:error, _} ->
        []

      rows ->
        Enum.map(rows, fn row ->
          struct(ConversationInfo, Map.put(row, :provider, struct(Provider, row.provider)))
        end)
    end
  end

  def create(name, ai_provider_id) when is_binary(ai_provider_id) do
    case Ecto.UUID.dump(ai_provider_id) do
      {:ok, binary_id} ->
        sql = """
        INSERT INTO conversations (
          name,
          ai_provider_id,
          inserted_at,
          updated_at)
        VALUES (
          $(name),
          $(ai_provider_id),
          $(inserted_at),
          $(updated_at)
        )
        """

        timestamp = now()

        params = %{
          "name" => name,
          "ai_provider_id" => binary_id,
          "inserted_at" => timestamp,
          "updated_at" => timestamp
        }

        case DbHelpers.run_sql(sql, params, "conversations") do
          {:error, :db_error} ->
            {:error, :db_error}

          _result ->
            :ok
        end

      :error ->
        {:error, :invalid_uuid}
    end
  end

  def find_id(name) do
    sql = "SELECT id FROM conversations WHERE name = $(name) LIMIT 1"
    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} ->
        {:error, :db_error}

      [] ->
        {:error, :not_found}

      [row | _] ->
        {:ok, row["id"]}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
