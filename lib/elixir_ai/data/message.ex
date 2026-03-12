defmodule ElixirAi.Message do
  use ElixirAi.Data
  alias ElixirAi.Repo
  alias ElixirAi.Data.MessageSchema

  def load_for_conversation(conversation_id, topic: topic) do
    broadcast_error topic: topic do
      with {:ok, db_conversation_id} <- dump_uuid(conversation_id) do
        sql = """
        SELECT role, content, reasoning_content, tool_calls, tool_call_id
        FROM messages
        WHERE conversation_id = $1
        ORDER BY id
        """

        result = Ecto.Adapters.SQL.query!(Repo, sql, [db_conversation_id])

        Enum.map(result.rows, fn row ->
          raw = %{
            role: Enum.at(row, 0),
            content: Enum.at(row, 1),
            reasoning_content: Enum.at(row, 2),
            tool_calls: Enum.at(row, 3),
            tool_call_id: Enum.at(row, 4)
          }

          case Zoi.parse(MessageSchema.schema(), raw) do
            {:ok, _valid} ->
              struct(MessageSchema, decode_message(raw))

            {:error, errors} ->
              Logger.error("Invalid message data from DB: #{inspect(errors)}")
              raise ArgumentError, "Invalid message data: #{inspect(errors)}"
          end
        end)
      else
        :error -> []
      end
    end
  end

  def insert(conversation_id, message, topic: topic) do
    broadcast_error topic: topic do
      with {:ok, db_conversation_id} <- dump_uuid(conversation_id) do
        sql = """
        INSERT INTO messages (
          conversation_id, role, content, reasoning_content,
          tool_calls, tool_call_id, inserted_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7)
        """

        params = [
          db_conversation_id,
          to_string(message.role),
          message[:content],
          message[:reasoning_content],
          encode_tool_calls(message[:tool_calls]),
          message[:tool_call_id],
          DateTime.truncate(DateTime.utc_now(), :second)
        ]

        Ecto.Adapters.SQL.query!(Repo, sql, params)
        Logger.debug("Inserted message for conversation_id=#{Ecto.UUID.cast!(conversation_id)}")
        {:ok, 1}
      else
        :error ->
          Logger.error("Invalid conversation_id for message insert: #{inspect(conversation_id)}")
          {:error, :invalid_conversation_id}
      end
    end
  end

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(calls), do: Jason.encode!(calls)

  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: {:ok, id}
  defp dump_uuid(id) when is_binary(id), do: Ecto.UUID.dump(id)
  defp dump_uuid(_), do: :error

  defp decode_message(row) do
    row
    |> Map.update!(:role, &String.to_existing_atom/1)
    |> Map.update(:tool_calls, nil, fn
      nil ->
        nil

      json when is_binary(json) ->
        json |> Jason.decode!() |> Enum.map(&atomize_keys/1)

      already_decoded ->
        Enum.map(already_decoded, &atomize_keys/1)
    end)
    |> drop_nil_fields()
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp drop_nil_fields(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
