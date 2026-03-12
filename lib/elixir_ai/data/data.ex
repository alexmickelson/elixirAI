defmodule ElixirAi.Data do
  defmacro __using__(_opts) do
    quote do
      import ElixirAi.Data
      require Logger
    end
  end

  defmacro broadcast_error(opts, do: block) do
    topic = Keyword.get(opts, :topic)
    build_with_db(block, topic)
  end

  defp build_with_db(block, topic) do
    quote do
      try do
        unquote(block)
      rescue
        exception ->
          Logger.error("Database error: #{Exception.message(exception)}")

          Phoenix.PubSub.broadcast(
            ElixirAi.PubSub,
            unquote(topic),
            {:db_error, Exception.message(exception)}
          )

          {:error, :db_error}
      end
    end
  end
end
