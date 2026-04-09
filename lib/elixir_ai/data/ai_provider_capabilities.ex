defmodule ElixirAi.AiProviderCapabilities do
  alias ElixirAi.Data.DbHelpers
  alias ElixirAi.AiProvider.AiProviderSchema
  require Logger
  import ElixirAi.PubsubTopics

  @exclusive_capabilities ~w(voice_assistant shell_classification)

  def valid, do: AiProviderSchema.valid_capabilities()

  def assign(_provider_id, []), do: :ok

  def assign(provider_id, capabilities) do
    sql = """
    INSERT INTO ai_provider_capabilities (ai_provider_id, capability_id)
    SELECT $(provider_id), c.id
    FROM capabilities c
    WHERE c.name = ANY($(capabilities)::text[])
    """

    params = %{"provider_id" => provider_id, "capabilities" => capabilities}

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} -> {:error, :db_error}
      _ -> :ok
    end
  end

  def update(id, capabilities) when is_list(capabilities) do
    invalid = Enum.reject(capabilities, &(&1 in valid()))

    if invalid != [] do
      {:error, {:invalid_capabilities, invalid}}
    else
      case Ecto.UUID.dump(id) do
        {:ok, binary_id} ->
          do_update(id, binary_id, capabilities)

        :error ->
          Logger.error("update_capabilities: invalid UUID #{inspect(id)}")
          {:error, :invalid_uuid}
      end
    end
  end

  defp do_update(id, binary_id, capabilities) do
    sql = """
    WITH
      stripped AS (
        DELETE FROM ai_provider_capabilities apc
        USING capabilities c
        WHERE apc.capability_id = c.id
          AND c.name = ANY(#{exclusive_array_literal()})
          AND apc.ai_provider_id != $(id)
          AND c.name = ANY($(capabilities)::text[])
        RETURNING apc.ai_provider_id AS affected_id
      ),
      removed AS (
        DELETE FROM ai_provider_capabilities apc
        USING capabilities c
        WHERE apc.capability_id = c.id
          AND apc.ai_provider_id = $(id)
          AND NOT (c.name = ANY($(capabilities)::text[]))
        RETURNING apc.ai_provider_id
      ),
      inserted AS (
        INSERT INTO ai_provider_capabilities (ai_provider_id, capability_id)
        SELECT $(id), c.id
        FROM capabilities c
        WHERE c.name = ANY($(capabilities)::text[])
        ON CONFLICT DO NOTHING
      )
    SELECT DISTINCT affected_id FROM stripped
    """

    params = %{"id" => binary_id, "capabilities" => capabilities}

    case DbHelpers.run_sql(sql, params, providers_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      rows ->
        other_ids =
          rows
          |> Enum.map(fn %{"affected_id" => bid} -> Ecto.UUID.cast!(bid) end)
          |> Enum.uniq()

        broadcast_updates(id, other_ids)
        :ok
    end
  end

  def find_provider(capability) when is_binary(capability) do
    sql = """
    SELECT
      ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url,
      COALESCE(array_agg(c.name) FILTER (WHERE c.name IS NOT NULL), '{}') AS capabilities
    FROM ai_providers ap
    LEFT JOIN ai_provider_capabilities apc ON apc.ai_provider_id = ap.id
    LEFT JOIN capabilities c ON c.id = apc.capability_id
    WHERE ap.id IN (
      SELECT apc2.ai_provider_id
      FROM ai_provider_capabilities apc2
      JOIN capabilities c2 ON c2.id = apc2.capability_id
      WHERE c2.name = $(capability)
    )
    GROUP BY ap.id, ap.name, ap.model_name, ap.api_token, ap.completions_url
    LIMIT 1
    """

    params = %{"capability" => capability}

    case DbHelpers.run_sql(sql, params, providers_topic(), AiProviderSchema.schema()) do
      {:error, _} -> {:error, :db_error}
      [] -> {:error, :not_found}
      [row | _] -> {:ok, row |> convert_uuid() |> then(&struct(AiProviderSchema, &1))}
    end
  end

  def get_voice_assistant, do: find_provider("voice_assistant")
  def get_shell_classifier, do: find_provider("shell_classification")

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp exclusive_array_literal do
    quoted = Enum.map_join(@exclusive_capabilities, ", ", &"'#{&1}'")
    "ARRAY[#{quoted}]"
  end

  defp broadcast_updates(id, other_affected_ids) do
    [id | other_affected_ids]
    |> Enum.uniq()
    |> Enum.each(fn updated_id ->
      Logger.info(
        "Provider updated, broadcasting :provider_updated to topic #{providers_topic()} for #{updated_id}"
      )

      Phoenix.PubSub.broadcast(
        ElixirAi.PubSub,
        providers_topic(),
        {:provider_updated, updated_id}
      )
    end)
  end

  defp convert_uuid(%{id: id} = row) when is_binary(id), do: %{row | id: Ecto.UUID.cast!(id)}
  defp convert_uuid(row), do: row
end
