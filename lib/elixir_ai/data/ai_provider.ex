defmodule ElixirAi.AiProvider do
  alias ElixirAi.Data.DbHelpers
  require Logger
  import ElixirAi.PubsubTopics

  defmodule AiProviderSchema do
    defstruct [:id, :name, :model_name, :api_token, :completions_url, :capabilities]

    def valid_capabilities, do: ["text", "image"]

    def schema do
      Zoi.object(%{
        id: Zoi.optional(Zoi.string()),
        name: Zoi.string(),
        model_name: Zoi.string(),
        api_token: Zoi.nullish(Zoi.string()),
        completions_url: Zoi.nullish(Zoi.string()),
        capabilities: Zoi.any()
      })
    end

    def partial_schema do
      Zoi.object(%{
        id: Zoi.optional(Zoi.string()),
        name: Zoi.string(),
        model_name: Zoi.string(),
        capabilities: Zoi.any()
      })
    end
  end

  def valid_capabilities, do: AiProviderSchema.valid_capabilities()

  def all do
    sql = "SELECT id, name, model_name, capabilities FROM ai_providers"
    params = %{}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.partial_schema()) do
      {:error, _} ->
        []

      rows ->
        rows
        |> Enum.map(fn row ->
          row
          |> convert_uuid_to_string()
          |> decode_capabilities()
          |> then(&struct(AiProviderSchema, &1))
        end)
        |> tap(&Logger.debug("AiProvider.all() returning: #{inspect(&1)}"))
    end
  end

  defp convert_uuid_to_string(%{id: id} = provider) when is_binary(id) do
    %{provider | id: Ecto.UUID.cast!(id)}
  end

  defp convert_uuid_to_string(provider), do: provider

  defp decode_capabilities(%{capabilities: caps} = provider) when is_list(caps), do: provider

  defp decode_capabilities(%{capabilities: caps} = provider) when is_binary(caps) do
    case Jason.decode(caps) do
      {:ok, list} when is_list(list) -> %{provider | capabilities: list}
      _ -> %{provider | capabilities: []}
    end
  end

  defp decode_capabilities(provider), do: %{provider | capabilities: []}

  def create(attrs) do
    capabilities = Map.get(attrs, :capabilities, ["text"])
    invalid_caps = Enum.reject(capabilities, &(&1 in AiProviderSchema.valid_capabilities()))

    if invalid_caps != [] do
      {:error, {:invalid_capabilities, invalid_caps}}
    else
      do_create(attrs, capabilities)
    end
  end

  defp do_create(attrs, capabilities) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    sql = """
    INSERT INTO ai_providers (
      name,
      model_name,
      api_token,
      completions_url,
      capabilities,
      inserted_at,
      updated_at
    ) VALUES (
      $(name),
      $(model_name),
      $(api_token),
      $(completions_url),
      $(capabilities)::jsonb,
      $(inserted_at),
      $(updated_at)
    )
    """

    params = %{
      "name" => attrs.name,
      "model_name" => attrs.model_name,
      "api_token" => attrs.api_token,
      "completions_url" => attrs.completions_url,
      "capabilities" => Jason.encode!(capabilities),
      "inserted_at" => now,
      "updated_at" => now
    }

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      _result ->
        Logger.info(
          "Provider created, broadcasting :provider_added message to topic #{providers_topic()}"
        )

        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          providers_topic(),
          {:provider_added, attrs}
        )

        :ok
    end
  end

  def update_capabilities(id, capabilities) when is_list(capabilities) do
    invalid_caps = Enum.reject(capabilities, &(&1 in AiProviderSchema.valid_capabilities()))

    if invalid_caps != [] do
      {:error, {:invalid_capabilities, invalid_caps}}
    else
      now = DateTime.truncate(DateTime.utc_now(), :second)

      sql = """
      UPDATE ai_providers
      SET capabilities = $(capabilities)::jsonb, updated_at = $(updated_at)
      WHERE id = $(id)::uuid
      """

      params = %{
        "capabilities" => Jason.encode!(capabilities),
        "updated_at" => now,
        "id" => id
      }

      case DbHelpers.run_sql(sql, params, providers_topic()) do
        {:error, :db_error} ->
          {:error, :db_error}

        _result ->
          Phoenix.PubSub.broadcast(
            ElixirAi.PubSub,
            providers_topic(),
            {:provider_updated, id}
          )

          :ok
      end
    end
  end

  def find_by_capability(capability) when is_binary(capability) do
    sql = """
    SELECT id, name, model_name, api_token, completions_url, capabilities
    FROM ai_providers
    WHERE capabilities @> $(capability)::jsonb
    LIMIT 1
    """

    params = %{"capability" => Jason.encode!([capability])}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
      {:error, _} ->
        {:error, :db_error}

      [] ->
        {:error, :not_found}

      [row | _] ->
        {:ok,
         row
         |> convert_uuid_to_string()
         |> decode_capabilities()
         |> then(&struct(AiProviderSchema, &1))}
    end
  end

  def find_by_name(name) do
    sql = """
    SELECT id, name, model_name, api_token, completions_url, capabilities
    FROM ai_providers
    WHERE name = $(name)
    LIMIT 1
    """

    params = %{"name" => name}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
      {:error, _} ->
        {:error, :db_error}

      [] ->
        {:error, :not_found}

      [row | _] ->
        {:ok,
         row
         |> convert_uuid_to_string()
         |> decode_capabilities()
         |> then(&struct(AiProviderSchema, &1))}
    end
  end

  def find_by_id(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary_id} ->
        sql = """
        SELECT id, name, model_name, api_token, completions_url, capabilities
        FROM ai_providers
        WHERE id = $(id)
        LIMIT 1
        """

        params = %{"id" => binary_id}

        case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
          {:error, _} ->
            {:error, :db_error}

          [] ->
            {:error, :not_found}

          [row | _] ->
            {:ok,
             row
             |> convert_uuid_to_string()
             |> decode_capabilities()
             |> then(&struct(AiProviderSchema, &1))}
        end

      :error ->
        {:error, :invalid_uuid}
    end
  end

  def delete(id) do
    sql = "DELETE FROM ai_providers WHERE id = $(id)::uuid"
    params = %{"id" => id}

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      _result ->
        Logger.info(
          "Provider deleted, broadcasting :provider_deleted message to topic #{providers_topic()}"
        )

        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          providers_topic(),
          {:provider_deleted, id}
        )

        :ok
    end
  end

  def ensure_default_provider do
    endpoint = Application.get_env(:elixir_ai, :ai_endpoint)
    token = Application.get_env(:elixir_ai, :ai_token)
    model = Application.get_env(:elixir_ai, :ai_model)

    if endpoint && token && model do
      case find_by_name("default") do
        {:error, :not_found} ->
          attrs = %{
            name: "default",
            model_name: model,
            api_token: token,
            completions_url: endpoint,
            capabilities: ["text"]
          }

          create(attrs)

        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      Logger.info("AI env vars not configured, skipping default provider creation")
      :ok
    end
  end

  def ensure_providers_from_file do
    case System.get_env("PROVIDERS_CONFIG_PATH") do
      nil ->
        :ok

      path ->
        case YamlElixir.read_from_file(path) do
          {:ok, %{"providers" => providers}} when is_list(providers) ->
            Enum.each(providers, &ensure_provider_from_yaml/1)

          {:ok, _} ->
            Logger.warning("providers.yml: expected a top-level 'providers' list, skipping")

          {:error, reason} ->
            Logger.warning("Could not read providers config from #{path}: #{inspect(reason)}")
        end
    end
  end

  def ensure_configured_providers do
    ensure_default_provider()
    ensure_providers_from_file()
  end

  defp ensure_provider_from_yaml(
         %{
           "name" => name,
           "model" => model,
           "responses_endpoint" => endpoint,
           "api_key" => api_key
         } = entry
       ) do
    capabilities = Map.get(entry, "capabilities", ["text"])

    case find_by_name(name) do
      {:error, :not_found} ->
        Logger.info("Creating provider '#{name}' from providers config file")

        create(%{
          name: name,
          model_name: model,
          api_token: api_key,
          completions_url: endpoint,
          capabilities: capabilities
        })

      {:ok, _} ->
        Logger.debug("Provider '#{name}' already exists, skipping")

      {:error, reason} ->
        Logger.warning("Could not check existence of provider '#{name}': #{inspect(reason)}")
    end
  end

  defp ensure_provider_from_yaml(entry) do
    Logger.warning(
      "Skipping invalid provider entry in providers config file (must have name, model, responses_endpoint, api_key): #{inspect(entry)}"
    )
  end
end
