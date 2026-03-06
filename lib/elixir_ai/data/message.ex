defmodule ElixirAi.Message do
  import Ecto.Query
  alias ElixirAi.Repo

  def load_for_conversation(conversation_id) do
    Repo.all(
      from m in "messages",
        where: m.conversation_id == ^conversation_id,
        order_by: m.id,
        select: %{
          role: m.role,
          content: m.content,
          reasoning_content: m.reasoning_content,
          tool_calls: m.tool_calls,
          tool_call_id: m.tool_call_id
        }
    )
    |> Enum.map(&decode_message/1)
  end

  def insert(conversation_id, message) do
    Repo.insert_all("messages", [
      [
        conversation_id: conversation_id,
        role: to_string(message.role),
        content: message[:content],
        reasoning_content: message[:reasoning_content],
        tool_calls: encode_tool_calls(message[:tool_calls]),
        tool_call_id: message[:tool_call_id],
        inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
      ]
    ])
  end

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(calls), do: Jason.encode!(calls)

  defp decode_message(row) do
    row
    |> Map.update!(:role, &String.to_existing_atom/1)
    |> Map.update(:tool_calls, nil, fn
        nil -> nil
        json when is_binary(json) ->
          json |> Jason.decode!() |> Enum.map(&atomize_keys/1)
        already_decoded -> Enum.map(already_decoded, &atomize_keys/1)
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
