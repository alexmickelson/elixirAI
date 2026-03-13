defmodule ElixirAi.AiProvider do
  alias ElixirAi.Data.DbHelpers
  require Logger
  import ElixirAi.PubsubTopics

  defmodule AiProviderSchema do
    defstruct [:id, :name, :model_name, :api_token, :completions_url]

    def schema do
      Zoi.object(%{
        id: Zoi.optional(Zoi.string()),
        name: Zoi.string(),
        model_name: Zoi.string(),
        api_token: Zoi.string(),
        completions_url: Zoi.string()
      })
    end

    def partial_schema do
      Zoi.object(%{
        id: Zoi.optional(Zoi.string()),
        name: Zoi.string(),
        model_name: Zoi.string()
      })
    end
  end

  def all do
    sql = "SELECT id, name, model_name FROM ai_providers"
    params = %{}

    case DbHelpers.run_sql(sql, params, "ai_providers", AiProviderSchema.partial_schema()) do
      {:error, _} ->
        []

      rows ->
        rows
        |> Enum.map(fn row ->
          row |> convert_uuid_to_string() |> then(&struct(AiProviderSchema, &1))
        end)
        |> tap(&Logger.debug("AiProvider.all() returning: #{inspect(&1)}"))
    end
  end

  defp convert_uuid_to_string(%{id: id} = provider) when is_binary(id) do
    %{provider | id: Ecto.UUID.cast!(id)}
  end

  defp convert_uuid_to_string(provider), do: provider

  def create(attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    sql = """
    INSERT INTO ai_providers (
      name,
      model_name,
      api_token,
      completions_url,
      inserted_at,
      updated_at
    ) VALUES (
      $(name),
      $(model_name),
      $(api_token),
      $(completions_url),
      $(inserted_at),
      $(updated_at)
    )
    """

    params = %{
      "name" => attrs.name,
      "model_name" => attrs.model_name,
      "api_token" => attrs.api_token,
      "completions_url" => attrs.completions_url,
      "inserted_at" => now,
      "updated_at" => now
    }

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      _result ->
        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          providers_topic(),
          {:provider_added, attrs}
        )

        :ok
    end
  end

  def find_by_name(name) do
    sql = """
    SELECT id, name, model_name, api_token, completions_url
    FROM ai_providers
    WHERE name = $(name)
    LIMIT 1
    """

    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
      {:error, _} -> {:error, :db_error}
      [] -> {:error, :not_found}
      [row | _] -> {:ok, row |> convert_uuid_to_string() |> then(&struct(AiProviderSchema, &1))}
    end
  end

  def ensure_default_provider do
    sql = "SELECT COUNT(*) FROM ai_providers"
    params = %{}

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      rows ->
        case rows do
          [%{"count" => 0}] ->
            attrs = %{
              name: "default",
              model_name: Application.fetch_env!(:elixir_ai, :ai_model),
              api_token: Application.fetch_env!(:elixir_ai, :ai_token),
              completions_url: Application.fetch_env!(:elixir_ai, :ai_endpoint)
            }

            create(attrs)

          _ ->
            :ok
        end
    end
  end
end
