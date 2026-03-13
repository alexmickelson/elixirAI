defmodule ElixirAi.Data.DbHelpers do
  require Logger
  @get_named_param ~r/\$\((\w+)\)/

  def run_sql(sql, params, topic, schema) do
    run_sql(sql, params, topic) |> validate_rows(schema, topic)
  end

  def run_sql(sql, params, topic) do
    original_sql = sql
    original_params = params
    {sql, params} = named_params_to_positional_params(sql, params)

    try do
      result = Ecto.Adapters.SQL.query!(ElixirAi.Repo, sql, params)

      # Transform rows to maps with column names as keys
      Enum.map(result.rows || [], fn row ->
        Enum.zip(result.columns, row)
        |> Enum.into(%{})
      end)
    rescue
      exception ->
        Logger.error("Database error: #{Exception.message(exception)}")
        Logger.error("Failed SQL: #{original_sql}")
        Logger.error("SQL params: #{inspect(original_params, pretty: true)}")

        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          topic,
          {:db_error, Exception.message(exception)}
        )

        {:error, :db_error}
    end
  end

  defp validate_rows({:error, :db_error}, _schema, _topic), do: {:error, :db_error}

  defp validate_rows(rows, schema, topic) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case Zoi.parse(schema, row, coerce: true) do
        {:ok, valid} ->
          {:cont, {:ok, [valid | acc]}}

        {:error, errors} ->
          Logger.error("Schema validation error: #{inspect(errors)}")
          {:halt, {:error, :validation_error}}
      end
    end)
    |> then(fn
      {:ok, valid_rows} ->
        Enum.reverse(valid_rows)

      error ->
        Logger.error("Validation error: #{inspect(error)}")
        Phoenix.PubSub.broadcast(ElixirAi.PubSub, topic, {:sql_result_validation_error, error})
        error
    end)
  end

  def named_params_to_positional_params(query, params) do
    param_occurrences = Regex.scan(@get_named_param, query)

    {param_to_index, ordered_values} =
      param_occurrences
      |> Enum.reduce({%{}, []}, fn [_full_match, param_name], {index_map, values} ->
        if Map.has_key?(index_map, param_name) do
          {index_map, values}
        else
          next_index = map_size(index_map) + 1
          param_value = Map.fetch!(params, param_name)
          {Map.put(index_map, param_name, next_index), values ++ [param_value]}
        end
      end)

    positional_sql =
      Regex.replace(@get_named_param, query, fn _full_match, param_name ->
        "$#{param_to_index[param_name]}"
      end)

    {positional_sql, ordered_values}
  end
end

defmodule ElixirAi.Repo do
  use Ecto.Repo,
    otp_app: :elixir_ai,
    adapter: Ecto.Adapters.Postgres
end
