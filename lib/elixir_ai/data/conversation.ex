defmodule ElixirAi.Conversation do
  alias ElixirAi.Data.DbHelpers
  require Logger

  defmodule Provider do
    defstruct [:name, :model_name, :api_token, :completions_url]

    def schema do
      Zoi.object(%{
        name: Zoi.string(),
        model_name: Zoi.string(),
        api_token: Zoi.nullish(Zoi.string()),
        completions_url: Zoi.nullish(Zoi.string())
      })
    end
  end

  defmodule ConversationInfo do
    defstruct [:name, :category, :provider]

    def schema do
      Zoi.object(%{
        name: Zoi.string(),
        category: Zoi.string(),
        provider:
          Zoi.object(%{
            name: Zoi.string(),
            model_name: Zoi.string(),
            api_token: Zoi.nullish(Zoi.string()),
            completions_url: Zoi.nullish(Zoi.string())
          })
      })
    end
  end

  def all_names do
    sql = "SELECT name, category FROM conversations"
    params = %{}

    schema = Zoi.object(%{name: Zoi.string(), category: Zoi.string()})

    case DbHelpers.run_sql(sql, params, "conversations", schema) do
      {:error, _} ->
        []

      rows ->
        Enum.map(rows, fn row ->
          struct(ConversationInfo, row)
        end)
    end
  end

  def create(name, ai_provider_id, category \\ "user-web", allowed_tools \\ nil)

  def create(name, ai_provider_id, category, nil),
    do: create(name, ai_provider_id, category, ElixirAi.AiTools.all_tool_names())

  def create(name, ai_provider_id, category, allowed_tools)
      when is_binary(ai_provider_id) and is_binary(category) and is_list(allowed_tools) do
    case Ecto.UUID.dump(ai_provider_id) do
      {:ok, binary_id} ->
        sql = """
        INSERT INTO conversations (
          name,
          ai_provider_id,
          category,
          allowed_tools,
          inserted_at,
          updated_at)
        VALUES (
          $(name),
          $(ai_provider_id),
          $(category),
          $(allowed_tools)::jsonb,
          $(inserted_at),
          $(updated_at)
        )
        """

        timestamp = now()

        params = %{
          "name" => name,
          "ai_provider_id" => binary_id,
          "category" => category,
          "allowed_tools" => Jason.encode!(allowed_tools),
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

  def find_allowed_tools(name) do
    sql = "SELECT allowed_tools FROM conversations WHERE name = $(name) LIMIT 1"
    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} -> {:error, :db_error}
      [] -> {:error, :not_found}
      [row | _] -> {:ok, decode_json_list(row["allowed_tools"])}
    end
  end

  defp decode_json_list(value) when is_list(value), do: value

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_json_list(_), do: []

  def update_allowed_tools(name, tool_names) when is_list(tool_names) do
    sql = """
    UPDATE conversations
    SET allowed_tools = $(allowed_tools)::jsonb, updated_at = $(updated_at)
    WHERE name = $(name)
    """

    params = %{
      "name" => name,
      "allowed_tools" => Jason.encode!(tool_names),
      "updated_at" => now()
    }

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} -> {:error, :db_error}
      _ -> :ok
    end
  end

  def find_tool_choice(name) do
    sql = "SELECT tool_choice FROM conversations WHERE name = $(name) LIMIT 1"
    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} -> {:error, :db_error}
      [] -> {:error, :not_found}
      [row | _] -> {:ok, row["tool_choice"] || "auto"}
    end
  end

  def update_tool_choice(name, tool_choice)
      when tool_choice in ["auto", "none", "required"] do
    sql = """
    UPDATE conversations
    SET tool_choice = $(tool_choice), updated_at = $(updated_at)
    WHERE name = $(name)
    """

    params = %{
      "name" => name,
      "tool_choice" => tool_choice,
      "updated_at" => now()
    }

    case DbHelpers.run_sql(sql, params, "conversations") do
      {:error, :db_error} -> {:error, :db_error}
      _ -> :ok
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

  def find_provider(name) do
    sql = """
    SELECT p.name, p.model_name, p.api_token, p.completions_url
    FROM conversations c
    JOIN ai_providers p ON c.ai_provider_id = p.id
    WHERE c.name = $(name)
    LIMIT 1
    """

    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, "conversations", Provider.schema()) do
      {:error, _} -> {:error, :db_error}
      [] -> {:error, :not_found}
      [row | _] -> {:ok, struct(Provider, row)}
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
