defmodule ElixirAi.AiProvider do
  alias ElixirAi.Data.DbHelpers
  require Logger

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

    case DbHelpers.run_sql(sql, params, "ai_providers") do
      {:error, :db_error} ->
        []

      result ->
        results =
          Enum.map(result.rows, fn [id, name, model_name] ->
            attrs = %{id: id, name: name, model_name: model_name} |> convert_id_to_string()

            case Zoi.parse(AiProviderSchema.partial_schema(), attrs) do
              {:ok, valid} ->
                struct(AiProviderSchema, valid)

              {:error, errors} ->
                Logger.error("Invalid provider data from DB: #{inspect(errors)}")
                raise ArgumentError, "Invalid provider data: #{inspect(errors)}"
            end
          end)

        Logger.debug("AiProvider.all() returning: #{inspect(results)}")

        results
    end
  end

  # Convert binary UUID to string for frontend
  defp convert_id_to_string(%{id: id} = provider) when is_binary(id) do
    %{provider | id: Ecto.UUID.cast!(id)}
  end

  defp convert_id_to_string(provider), do: provider

  def create(attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    sql = """
    INSERT INTO ai_providers (name, model_name, api_token, completions_url, inserted_at, updated_at)
    VALUES ($(name), $(model_name), $(api_token), $(completions_url), $(inserted_at), $(updated_at))
    """

    params = %{
      "name" => attrs.name,
      "model_name" => attrs.model_name,
      "api_token" => attrs.api_token,
      "completions_url" => attrs.completions_url,
      "inserted_at" => now,
      "updated_at" => now
    }

    case DbHelpers.run_sql(sql, params, "ai_providers") do
      {:error, :db_error} ->
        {:error, :db_error}

      _result ->
        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          "ai_providers",
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

    case DbHelpers.run_sql(sql, params, "ai_providers") do
      {:error, :db_error} ->
        {:error, :db_error}

      %{rows: []} ->
        {:error, :not_found}

      %{rows: [[id, name, model_name, api_token, completions_url] | _]} ->
        attrs =
          %{
            id: id,
            name: name,
            model_name: model_name,
            api_token: api_token,
            completions_url: completions_url
          }
          |> convert_id_to_string()

        case Zoi.parse(AiProviderSchema.schema(), attrs) do
          {:ok, valid} ->
            {:ok, struct(AiProviderSchema, valid)}

          {:error, errors} ->
            Logger.error("Invalid provider data from DB: #{inspect(errors)}")
            {:error, :invalid_data}
        end
    end
  end

  def ensure_default_provider do
    sql = "SELECT COUNT(*) FROM ai_providers"
    params = %{}

    case DbHelpers.run_sql(sql, params, "ai_providers") do
      {:error, :db_error} ->
        {:error, :db_error}

      result ->
        case result.rows do
          [[0]] ->
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
