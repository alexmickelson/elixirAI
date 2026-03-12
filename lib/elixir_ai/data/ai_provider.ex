defmodule ElixirAi.AiProvider do
  use ElixirAi.Data
  alias ElixirAi.Repo
  alias ElixirAi.Data.AiProviderSchema

  def all do
    broadcast_error topic: "ai_providers" do
      sql = "SELECT id, name, model_name FROM ai_providers"
      result = Ecto.Adapters.SQL.query!(Repo, sql, [])

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
    broadcast_error topic: "ai_providers" do
      now = DateTime.truncate(DateTime.utc_now(), :second)

      sql = """
      INSERT INTO ai_providers (name, model_name, api_token, completions_url, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6)
      """

      params = [attrs.name, attrs.model_name, attrs.api_token, attrs.completions_url, now, now]

      Ecto.Adapters.SQL.query!(Repo, sql, params)

      Phoenix.PubSub.broadcast(
        ElixirAi.PubSub,
        "ai_providers",
        {:provider_added, attrs}
      )

      :ok
    end
  end

  def find_by_name(name) do
    broadcast_error topic: "ai_providers" do
      sql = """
      SELECT id, name, model_name, api_token, completions_url
      FROM ai_providers
      WHERE name = $1
      LIMIT 1
      """

      case Ecto.Adapters.SQL.query!(Repo, sql, [name]) do
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
  end

  def ensure_default_provider do
    broadcast_error topic: "ai_providers" do
      sql = "SELECT COUNT(*) FROM ai_providers"
      result = Ecto.Adapters.SQL.query!(Repo, sql, [])

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
