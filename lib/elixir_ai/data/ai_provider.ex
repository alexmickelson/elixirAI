defmodule ElixirAi.AiProvider do
  alias ElixirAi.Data.DbHelpers
  alias ElixirAi.AiProviderCapabilities
  require Logger
  import ElixirAi.PubsubTopics

  defmodule AiProviderSchema do
    defstruct [:id, :name, :model_name, :api_token, :completions_url, :capabilities, :inserted_at]

    def valid_capabilities, do: ["text", "image", "voice_assistant", "shell_classification"]

    def schema do
      Zoi.object(%{
        id: Zoi.optional(Zoi.string()),
        name: Zoi.string(),
        model_name: Zoi.string(),
        api_token: Zoi.optional(Zoi.nullish(Zoi.string())),
        completions_url: Zoi.optional(Zoi.nullish(Zoi.string())),
        capabilities: Zoi.any(),
        inserted_at: Zoi.optional(Zoi.any())
      })
    end
  end

  def valid_capabilities, do: AiProviderCapabilities.valid()

  def all do
    sql = """
    SELECT
      ap.id, ap.name, ap.model_name,
      COALESCE(array_agg(c.name) FILTER (WHERE c.name IS NOT NULL), '{}') AS capabilities,
      ap.inserted_at
    FROM ai_providers ap
    LEFT JOIN ai_provider_capabilities apc ON apc.ai_provider_id = ap.id
    LEFT JOIN capabilities c ON c.id = apc.capability_id
    GROUP BY ap.id, ap.name, ap.model_name, ap.inserted_at
    ORDER BY ap.inserted_at ASC
    """

    params = %{}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
      {:error, _} ->
        []

      rows ->
        rows
        |> Enum.map(fn row ->
          row
          |> convert_uuid_to_string()
          |> then(&struct(AiProviderSchema, &1))
        end)
        |> tap(&Logger.debug("AiProvider.all() returning: #{inspect(&1)}"))
    end
  end

  defp convert_uuid_to_string(%{id: id} = provider) when is_binary(id) do
    %{provider | id: Ecto.UUID.cast!(id)}
  end

  defp convert_uuid_to_string(provider), do: provider

  def create(attrs) do
    capabilities = attrs |> Map.get(:capabilities, [])
    invalid_caps = capabilities |> Enum.reject(&(&1 in AiProviderCapabilities.valid()))

    if invalid_caps != [] do
      {:error, {:invalid_capabilities, invalid_caps}}
    else
      do_create(attrs, capabilities)
    end
  end

  defp do_create(attrs, capabilities) do
    provider_sql = """
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
      NOW(),
      NOW()
    )
    RETURNING id
    """

    provider_params = %{
      "name" => attrs.name,
      "model_name" => attrs.model_name,
      "api_token" => attrs.api_token,
      "completions_url" => attrs.completions_url
    }

    case DbHelpers.run_sql(provider_sql, provider_params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      [%{"id" => provider_id} | _] ->
        case AiProviderCapabilities.assign(provider_id, capabilities) do
          :ok ->
            Logger.info(
              "Provider created, broadcasting :provider_added message to topic #{providers_topic()}"
            )

            Phoenix.PubSub.broadcast(
              ElixirAi.PubSub,
              providers_topic(),
              {:provider_added, attrs}
            )

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defdelegate update_capabilities(id, capabilities), to: AiProviderCapabilities, as: :update
  defdelegate find_by_capability(capability), to: AiProviderCapabilities, as: :find_provider
  defdelegate get_voice_assistant(), to: AiProviderCapabilities
  defdelegate get_shell_classifier(), to: AiProviderCapabilities

  def find_by_name(name) do
    sql = """
    SELECT
      ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url,
      COALESCE(array_agg(c.name) FILTER (WHERE c.name IS NOT NULL), '{}') AS capabilities
    FROM ai_providers ap
    LEFT JOIN ai_provider_capabilities apc ON apc.ai_provider_id = ap.id
    LEFT JOIN capabilities c ON c.id = apc.capability_id
    WHERE ap.name = $(name)
    GROUP BY ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url
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
         |> then(&struct(AiProviderSchema, &1))}
    end
  end

  def find_by_id(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary_id} ->
        sql = """
        SELECT
          ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url,
          COALESCE(array_agg(c.name) FILTER (WHERE c.name IS NOT NULL), '{}') AS capabilities
        FROM ai_providers ap
        LEFT JOIN ai_provider_capabilities apc ON apc.ai_provider_id = ap.id
        LEFT JOIN capabilities c ON c.id = apc.capability_id
        WHERE ap.id = $(id)
        GROUP BY ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url
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
             |> then(&struct(AiProviderSchema, &1))}
        end

      :error ->
        {:error, :invalid_uuid}
    end
  end

  def delete(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary_id} ->
        sql = "DELETE FROM ai_providers WHERE id = $(id)"
        params = %{"id" => binary_id}

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

      :error ->
        {:error, :invalid_uuid}
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
