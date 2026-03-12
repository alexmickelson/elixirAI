defmodule ElixirAi.Conversation do
  use ElixirAi.Data
  alias ElixirAi.Repo

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
    broadcast_error topic: "conversations" do
      sql = """
      SELECT c.name, p.name, p.model_name, p.api_token, p.completions_url
      FROM conversations c
      LEFT JOIN ai_providers p ON c.ai_provider_id = p.id
      """

      result = Ecto.Adapters.SQL.query!(Repo, sql, [])

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
            struct(ConversationInfo, Map.put(valid, :provider, struct(Provider, valid.provider)))

          {:error, errors} ->
            Logger.error("Invalid conversation data: #{inspect(errors)}")
            raise ArgumentError, "Invalid conversation data: #{inspect(errors)}"
        end
      end)
    end
  end

  def create(name, ai_provider_id) when is_binary(ai_provider_id) do
    broadcast_error topic: "conversations" do
      case Ecto.UUID.dump(ai_provider_id) do
        {:ok, binary_id} ->
          sql = """
          INSERT INTO conversations (name, ai_provider_id, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4)
          """

          timestamp = now()
          params = [name, binary_id, timestamp, timestamp]

          Ecto.Adapters.SQL.query!(Repo, sql, params)
          :ok

        :error ->
          {:error, :invalid_uuid}
      end
    end
  end

  def find_id(name) do
    broadcast_error topic: "conversations" do
      sql = "SELECT id FROM conversations WHERE name = $1 LIMIT 1"

      case Ecto.Adapters.SQL.query!(Repo, sql, [name]) do
        %{rows: []} -> {:error, :not_found}
        %{rows: [[id] | _]} -> {:ok, id}
      end
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
