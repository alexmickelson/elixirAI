defmodule ElixirAi.Data.DbHelpers do
  require Logger
  @get_named_param ~r/\$\((\w+)\)/

  def run_sql(sql, params, topic) do
    {sql, params} = named_params_to_positional_params(sql, params)

    try do
      Ecto.Adapters.SQL.query!(ElixirAi.Repo, sql, params)
    rescue
      exception ->
        Logger.error("Database error: #{Exception.message(exception)}")

        Phoenix.PubSub.broadcast(
          ElixirAi.PubSub,
          topic,
          {:db_error, Exception.message(exception)}
        )

        {:error, :db_error}
    end
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
