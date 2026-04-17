defmodule ElixirAi.McpServer do
  @moduledoc """
  Data access for the `mcp_servers` table — CRUD operations for MCP server
  configurations that are persisted across restarts.
  """

  alias ElixirAi.Data.DbHelpers
  require Logger
  import ElixirAi.PubsubTopics

  defstruct [:id, :name, :url, :headers, :enabled, :inserted_at]

  def all do
    sql = """
    SELECT id, name, url, headers, enabled, inserted_at
    FROM mcp_servers
    ORDER BY inserted_at ASC
    """

    case DbHelpers.run_sql(sql, %{}, mcp_topic()) do
      {:error, _} ->
        []

      rows ->
        Enum.map(rows, fn row ->
          %__MODULE__{
            id: row["id"],
            name: row["name"],
            url: row["url"],
            headers: decode_headers(row["headers"]),
            enabled: row["enabled"],
            inserted_at: row["inserted_at"]
          }
        end)
    end
  end

  def all_enabled do
    Enum.filter(all(), & &1.enabled)
  end

  def find_by_name(name) do
    sql = """
    SELECT id, name, url, headers, enabled, inserted_at
    FROM mcp_servers
    WHERE name = $(name)
    LIMIT 1
    """

    case DbHelpers.run_sql(sql, %{"name" => name}, mcp_topic()) do
      {:error, _} ->
        {:error, :db_error}

      [] ->
        {:error, :not_found}

      [row | _] ->
        {:ok,
         %__MODULE__{
           id: row["id"],
           name: row["name"],
           url: row["url"],
           headers: decode_headers(row["headers"]),
           enabled: row["enabled"],
           inserted_at: row["inserted_at"]
         }}
    end
  end

  def create(attrs) when is_map(attrs) do
    sql = """
    INSERT INTO mcp_servers (name, url, headers, enabled, inserted_at, updated_at)
    VALUES ($(name), $(url), $(headers)::jsonb, $(enabled), NOW(), NOW())
    RETURNING id
    """

    params = %{
      "name" => attrs.name,
      "url" => attrs.url,
      "headers" => Jason.encode!(attrs[:headers] || %{}),
      "enabled" => Map.get(attrs, :enabled, true)
    }

    case DbHelpers.run_sql(sql, params, mcp_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      [%{"id" => _id} | _] ->
        Phoenix.PubSub.broadcast(ElixirAi.PubSub, mcp_topic(), {:mcp_server_added, attrs})
        :ok
    end
  end

  def delete(name) when is_binary(name) do
    sql = "DELETE FROM mcp_servers WHERE name = $(name)"

    case DbHelpers.run_sql(sql, %{"name" => name}, mcp_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      _ ->
        Phoenix.PubSub.broadcast(ElixirAi.PubSub, mcp_topic(), {:mcp_server_deleted, name})
        :ok
    end
  end

  def update_enabled(name, enabled) when is_binary(name) and is_boolean(enabled) do
    sql = """
    UPDATE mcp_servers SET enabled = $(enabled), updated_at = NOW()
    WHERE name = $(name)
    """

    case DbHelpers.run_sql(sql, %{"name" => name, "enabled" => enabled}, mcp_topic()) do
      {:error, :db_error} ->
        {:error, :db_error}

      _ ->
        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          mcp_topic(),
          {:mcp_server_updated, name, %{enabled: enabled}}
        )

        :ok
    end
  end

  def ensure_mcp_servers_from_file do
    case System.get_env("PROVIDERS_CONFIG_PATH") do
      nil ->
        :ok

      path ->
        case YamlElixir.read_from_file(path) do
          {:ok, %{"mcp_servers" => servers}} when is_list(servers) ->
            Enum.each(servers, &ensure_server_from_yaml/1)

          {:ok, _} ->
            Logger.debug("No mcp_servers section in providers config, skipping")

          {:error, reason} ->
            Logger.warning("Could not read providers config from #{path}: #{inspect(reason)}")
        end
    end
  end

  defp ensure_server_from_yaml(%{"name" => name, "url" => url} = entry) do
    case find_by_name(name) do
      {:error, :not_found} ->
        Logger.info("Creating MCP server '#{name}' from providers config file")

        create(%{
          name: name,
          url: url,
          headers: Map.get(entry, "headers", %{})
        })

      {:ok, _} ->
        Logger.debug("MCP server '#{name}' already exists, skipping")

      {:error, reason} ->
        Logger.warning("Could not check existence of MCP server '#{name}': #{inspect(reason)}")
    end
  end

  defp ensure_server_from_yaml(entry) do
    Logger.warning("Skipping invalid MCP server entry (must have name, url): #{inspect(entry)}")
  end

  defp decode_headers(nil), do: %{}
  defp decode_headers(headers) when is_map(headers), do: headers

  defp decode_headers(headers) when is_binary(headers) do
    case Jason.decode(headers) do
      {:ok, map} -> map
      _ -> %{}
    end
  end
end
