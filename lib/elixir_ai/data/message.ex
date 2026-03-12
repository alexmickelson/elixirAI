defmodule ElixirAi.Message do
  alias ElixirAi.Data.DbHelpers
  require Logger

  defmodule MessageSchema do
    defstruct [:role, :content, :reasoning_content, :tool_calls, :tool_call_id]

    def schema do
      Zoi.object(%{
        role: Zoi.enum([:user, :assistant, :tool]),
        content: Zoi.optional(Zoi.string()),
        reasoning_content: Zoi.optional(Zoi.string()),
        tool_calls: Zoi.optional(Zoi.any()),
        tool_call_id: Zoi.optional(Zoi.string())
      })
    end
  end

  def load_for_conversation(conversation_id, topic: topic)
      when is_binary(conversation_id) and byte_size(conversation_id) == 16 do
    sql = """
    SELECT role, content, reasoning_content, tool_calls, tool_call_id
    FROM messages
    WHERE conversation_id = $(conversation_id)
    ORDER BY id
    """

    params = %{"conversation_id" => conversation_id}

    case DbHelpers.run_sql(sql, params, topic) do
      {:error, :db_error} ->
        []

      result ->
        Enum.map(result.rows, fn row ->
          raw = %{
            role: Enum.at(row, 0),
            content: Enum.at(row, 1),
            reasoning_content: Enum.at(row, 2),
            tool_calls: Enum.at(row, 3),
            tool_call_id: Enum.at(row, 4)
          }

          decoded = decode_message(raw)

          case Zoi.parse(MessageSchema.schema(), decoded) do
            {:ok, _valid} ->
              struct(MessageSchema, decoded)

            {:error, errors} ->
              Logger.error("Invalid message data from DB: #{inspect(errors)}")
              raise ArgumentError, "Invalid message data: #{inspect(errors)}"
          end
        end)
    end
  end

  def load_for_conversation(conversation_id, topic: topic) do
    case dump_uuid(conversation_id) do
      {:ok, db_conversation_id} ->
        load_for_conversation(db_conversation_id, topic: topic)

      :error ->
        []
    end
  end

  def insert(conversation_id, message, topic: topic)
      when is_binary(conversation_id) and byte_size(conversation_id) == 16 do
    sql = """
    INSERT INTO messages (
      conversation_id, role, content, reasoning_content,
      tool_calls, tool_call_id, inserted_at
    ) VALUES ($(conversation_id), $(role), $(content), $(reasoning_content), $(tool_calls), $(tool_call_id), $(inserted_at))
    """

    params = %{
      "conversation_id" => conversation_id,
      "role" => to_string(message.role),
      "content" => message[:content],
      "reasoning_content" => message[:reasoning_content],
      "tool_calls" => encode_tool_calls(message[:tool_calls]),
      "tool_call_id" => message[:tool_call_id],
      "inserted_at" => DateTime.truncate(DateTime.utc_now(), :second)
    }

    case DbHelpers.run_sql(sql, params, topic) do
      {:error, :db_error} ->
        {:error, :db_error}

      _result ->
        # Logger.debug("Inserted message for conversation_id=#{Ecto.UUID.cast!(conversation_id)}")
        {:ok, 1}
    end
  end

  def insert(conversation_id, message, topic: topic) do
    case dump_uuid(conversation_id) do
      {:ok, db_conversation_id} ->
        insert(db_conversation_id, message, topic: topic)

      :error ->
        Logger.error("Invalid conversation_id for message insert: #{inspect(conversation_id)}")
        {:error, :invalid_conversation_id}
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
