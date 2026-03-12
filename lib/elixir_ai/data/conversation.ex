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
    SELECT c.name, p.name, p.model_name, p.api_token, p.completions_url
    FROM conversations c
    LEFT JOIN ai_providers p ON c.ai_provider_id = p.id
    """

    params = %{}

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} ->
        []

      result ->
        Enum.map(result.rows, fn [name, provider_name, model_name, api_token, completions_url] ->
          attrs = %{
            name: name,
            provider: %{
              name: provider_name,
              model_name: model_name,
              api_token: api_token,
              completions_url: completions_url
            }
          }

          case Zoi.parse(ConversationInfo.schema(), attrs) do
            {:ok, valid} ->
              struct(
                ConversationInfo,
                Map.put(valid, :provider, struct(Provider, valid.provider))
              )

            {:error, errors} ->
              Logger.error("Invalid conversation data: #{inspect(errors)}")
              raise ArgumentError, "Invalid conversation data: #{inspect(errors)}"
          end
        end)
    end
  end

  def create(name, ai_provider_id) when is_binary(ai_provider_id) do
    case Ecto.UUID.dump(ai_provider_id) do
      {:ok, binary_id} ->
        sql = """
        INSERT INTO conversations (name, ai_provider_id, inserted_at, updated_at)
        VALUES ($(name), $(ai_provider_id), $(inserted_at), $(updated_at))
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

      %{rows: []} ->
        {:error, :not_found}

      %{rows: [[id] | _]} ->
        {:ok, id}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
