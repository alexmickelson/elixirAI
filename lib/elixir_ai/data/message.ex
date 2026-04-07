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

  # Row schemas for the three message tables
  defp text_message_row_schema do
    Zoi.object(%{
      id: Zoi.integer(),
      prev_message_id: Zoi.nullish(Zoi.integer()),
      prev_message_table: Zoi.nullish(Zoi.string()),
      role: Zoi.string(),
      content: Zoi.nullish(Zoi.string()),
      reasoning_content: Zoi.nullish(Zoi.string()),
      tool_choice: Zoi.nullish(Zoi.string()),
      inserted_at: Zoi.any()
    })
  end

  defp tool_call_request_row_schema do
    Zoi.object(%{
      id: Zoi.integer(),
      text_message_id: Zoi.integer(),
      prev_message_id: Zoi.nullish(Zoi.integer()),
      prev_message_table: Zoi.nullish(Zoi.string()),
      tool_name: Zoi.string(),
      tool_call_id: Zoi.string(),
      arguments: Zoi.any(),
      inserted_at: Zoi.any()
    })
  end

  defp tool_response_row_schema do
    Zoi.object(%{
      id: Zoi.integer(),
      tool_call_id: Zoi.string(),
      prev_message_id: Zoi.nullish(Zoi.integer()),
      prev_message_table: Zoi.nullish(Zoi.string()),
      content: Zoi.string(),
      inserted_at: Zoi.any()
    })
  end

  def load_for_conversation(conversation_id, topic: topic)
      when is_binary(conversation_id) and byte_size(conversation_id) == 16 do
    with text_messages when is_list(text_messages) <- fetch_text_messages(conversation_id, topic),
         tool_call_msgs when is_list(tool_call_msgs) <-
           fetch_tool_call_request_messages(conversation_id, topic),
         tool_response_msgs when is_list(tool_response_msgs) <-
           fetch_tool_response_messages(conversation_id, topic) do
      tagged =
        Enum.map(text_messages, &Map.put(&1, :_table, "text_messages")) ++
          Enum.map(tool_call_msgs, &Map.put(&1, :_table, "tool_calls_request_messages")) ++
          Enum.map(tool_response_msgs, &Map.put(&1, :_table, "tool_response_messages"))

      by_key = Map.new(tagged, fn row -> {{row._table, row.id}, row} end)

      ordered = sort_by_prev_message(tagged, by_key)

      Enum.map(ordered, fn row ->
        case row._table do
          "text_messages" ->
            %MessageSchema{
              role: String.to_existing_atom(row.role),
              content: row[:content],
              reasoning_content: row[:reasoning_content],
              tool_calls: []
            }

          "tool_calls_request_messages" ->
            %MessageSchema{
              role: :assistant,
              tool_calls: [
                %{
                  id: row.tool_call_id,
                  name: row.tool_name,
                  arguments: row.arguments
                }
              ]
            }

          "tool_response_messages" ->
            %MessageSchema{
              role: :tool,
              content: row.content,
              tool_call_id: row.tool_call_id
            }
        end
      end)
      |> Enum.map(&drop_nil_fields(Map.from_struct(&1)))
      |> Enum.map(&struct(MessageSchema, &1))
    else
      _ -> []
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

  defp fetch_text_messages(conversation_id, topic) do
    sql = """
    SELECT
      tm.id,
      tm.prev_message_id,
      tm.prev_message_table,
      tm.role,
      tm.content,
      tm.reasoning_content,
      tm.tool_choice,
      tm.inserted_at
    FROM text_messages tm
    WHERE tm.conversation_id = $(conversation_id)
    """

    DbHelpers.run_sql(
      sql,
      %{"conversation_id" => conversation_id},
      topic,
      text_message_row_schema()
    ) || []
  end

  defp fetch_tool_call_request_messages(conversation_id, topic) do
    sql = """
    SELECT
      tc.id,
      tc.text_message_id,
      tc.prev_message_id,
      tc.prev_message_table,
      tc.tool_name,
      tc.tool_call_id,
      tc.arguments,
      tc.inserted_at
    FROM tool_calls_request_messages tc
    JOIN text_messages tm ON tc.text_message_id = tm.id
    WHERE tm.conversation_id = $(conversation_id)
    """

    DbHelpers.run_sql(
      sql,
      %{"conversation_id" => conversation_id},
      topic,
      tool_call_request_row_schema()
    ) || []
  end

  defp fetch_tool_response_messages(conversation_id, topic) do
    sql = """
    SELECT
      tr.id,
      tr.tool_call_id,
      tr.prev_message_id,
      tr.prev_message_table,
      tr.content,
      tr.inserted_at
    FROM tool_response_messages tr
    JOIN tool_calls_request_messages tc ON tr.tool_call_id = tc.tool_call_id
    JOIN text_messages tm ON tc.text_message_id = tm.id
    WHERE tm.conversation_id = $(conversation_id)
    """

    DbHelpers.run_sql(
      sql,
      %{"conversation_id" => conversation_id},
      topic,
      tool_response_row_schema()
    ) || []
  end

  def insert(conversation_id, message, topic: topic)
      when is_binary(conversation_id) and byte_size(conversation_id) == 16 do
    case message.role do
      :tool ->
        insert_tool_response(message, topic)

      :assistant ->
        insert_assistant_message(conversation_id, message, topic)

      :user ->
        insert_user_message(conversation_id, message, topic)
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

  defp insert_user_message(conversation_id, message, topic) do
    {prev_id, prev_table} = get_last_message_ref(conversation_id, topic)

    sql = """
    INSERT INTO text_messages (
      conversation_id,
      prev_message_id,
      prev_message_table,
      role,
      content,
      tool_choice,
      inserted_at
    ) VALUES (
      $(conversation_id),
      $(prev_message_id),
      $(prev_message_table),
      $(role),
      $(content),
      $(tool_choice),
      NOW()
    )
    """

    params = %{
      "conversation_id" => conversation_id,
      "prev_message_id" => prev_id,
      "prev_message_table" => prev_table,
      "role" => "user",
      "content" => message[:content],
      "tool_choice" => message[:tool_choice]
    }

    case DbHelpers.run_sql(sql, params, topic) do
      {:error, :db_error} -> {:error, :db_error}
      _result -> {:ok, 1}
    end
  end

  defp insert_assistant_message(conversation_id, message, topic) do
    {prev_id, prev_table} = get_last_message_ref(conversation_id, topic)

    message_sql = """
    INSERT INTO text_messages (
      conversation_id,
      prev_message_id,
      prev_message_table,
      role,
      content,
      reasoning_content,
      inserted_at
    ) VALUES (
      $(conversation_id),
      $(prev_message_id),
      $(prev_message_table),
      $(role),
      $(content),
      $(reasoning_content),
      NOW()
    )
    RETURNING id
    """

    message_params = %{
      "conversation_id" => conversation_id,
      "prev_message_id" => prev_id,
      "prev_message_table" => prev_table,
      "role" => "assistant",
      "content" => message[:content],
      "reasoning_content" => message[:reasoning_content]
    }

    case DbHelpers.run_sql(message_sql, message_params, topic) do
      {:error, :db_error} ->
        {:error, :db_error}

      [%{"id" => text_message_id}] ->
        if message[:tool_calls] && length(message[:tool_calls]) > 0 do
          Enum.each(message[:tool_calls], fn tool_call ->
            {tc_prev_id, tc_prev_table} = get_last_message_ref(conversation_id, topic)

            tool_call_sql = """
            INSERT INTO tool_calls_request_messages (
              text_message_id,
              prev_message_id,
              prev_message_table,
              tool_name,
              tool_call_id,
              arguments,
              inserted_at
            ) VALUES (
              $(text_message_id),
              $(prev_message_id),
              $(prev_message_table),
              $(tool_name),
              $(tool_call_id),
              $(arguments)::jsonb,
              NOW()
            )
            """

            tool_call_params = %{
              "text_message_id" => text_message_id,
              "prev_message_id" => tc_prev_id,
              "prev_message_table" => tc_prev_table,
              "tool_name" => tool_call[:name] || tool_call["name"],
              "tool_call_id" => tool_call[:id] || tool_call["id"],
              "arguments" =>
                encode_tool_call_arguments(tool_call[:arguments] || tool_call["arguments"])
            }

            DbHelpers.run_sql(tool_call_sql, tool_call_params, topic)
          end)
        end

        {:ok, 1}

      _ ->
        {:error, :db_error}
    end
  end

  defp insert_tool_response(message, topic) do
    # tool_response_messages has no conversation_id, so look up via the tool_call
    tool_call_id = message[:tool_call_id]

    {prev_id, prev_table} = get_last_tool_response_ref(tool_call_id, topic)

    sql = """
    INSERT INTO tool_response_messages (
      tool_call_id,
      prev_message_id,
      prev_message_table,
      content
    ) VALUES (
      $(tool_call_id),
      $(prev_message_id),
      $(prev_message_table),
      $(content)
    )
    """

    params = %{
      "tool_call_id" => tool_call_id,
      "prev_message_id" => prev_id,
      "prev_message_table" => prev_table,
      "content" => message[:content] || ""
    }

    case DbHelpers.run_sql(sql, params, topic) do
      {:error, :db_error} -> {:error, :db_error}
      _result -> {:ok, 1}
    end
  end

  # Returns {id, table_name} of the most recently inserted message in the conversation,
  # searching text_messages, tool_calls_request_messages, and tool_response_messages.
  defp get_last_message_ref(conversation_id, topic) do
    sql = """
    SELECT id, 'text_messages' AS tbl, inserted_at
    FROM text_messages WHERE conversation_id = $(conversation_id)
    UNION ALL
    SELECT tc.id, 'tool_calls_request_messages', tc.inserted_at
    FROM tool_calls_request_messages tc
    JOIN text_messages tm ON tc.text_message_id = tm.id
    WHERE tm.conversation_id = $(conversation_id)
    UNION ALL
    SELECT tr.id, 'tool_response_messages', tr.inserted_at
    FROM tool_response_messages tr
    JOIN tool_calls_request_messages tc ON tr.tool_call_id = tc.tool_call_id
    JOIN text_messages tm ON tc.text_message_id = tm.id
    WHERE tm.conversation_id = $(conversation_id)
    ORDER BY inserted_at DESC, id DESC
    LIMIT 1
    """

    case DbHelpers.run_sql(sql, %{"conversation_id" => conversation_id}, topic) do
      [%{"id" => id, "tbl" => tbl}] -> {id, tbl}
      _ -> {nil, nil}
    end
  end

  defp get_last_tool_response_ref(tool_call_id, topic) do
    sql = """
    SELECT tc.id, 'tool_calls_request_messages' AS tbl
    FROM tool_calls_request_messages tc
    WHERE tc.tool_call_id = $(tool_call_id)
    LIMIT 1
    """

    case DbHelpers.run_sql(sql, %{"tool_call_id" => tool_call_id}, topic) do
      [%{"id" => id, "tbl" => tbl}] -> {id, tbl}
      _ -> {nil, nil}
    end
  end

  defp sort_by_prev_message([], _by_key), do: []

  defp sort_by_prev_message(rows, _by_key) do
    # Find the head: the row whose {prev_message_table, prev_message_id} is not in the set,
    # i.e. it has no predecessor among this conversation's messages.
    keys = MapSet.new(rows, fn r -> {r._table, r.id} end)

    head =
      Enum.find(rows, fn r ->
        prev_key = {r[:prev_message_table], r[:prev_message_id]}
        is_nil(r[:prev_message_id]) or not MapSet.member?(keys, prev_key)
      end)

    if is_nil(head) do
      rows
    else
      # Build a reverse index: prev pointer -> row that points to it
      by_prev =
        Map.new(rows, fn r ->
          {{r[:prev_message_table], r[:prev_message_id]}, r}
        end)

      Stream.iterate(head, fn r ->
        Map.get(by_prev, {r._table, r.id})
      end)
      |> Enum.take_while(&(&1 != nil))
    end
  end

  defp encode_tool_call_arguments(args) when is_binary(args), do: args
  defp encode_tool_call_arguments(args), do: Jason.encode!(args)

  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: {:ok, id}
  defp dump_uuid(id) when is_binary(id), do: Ecto.UUID.dump(id)
  defp dump_uuid(_), do: :error

  defp drop_nil_fields(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
