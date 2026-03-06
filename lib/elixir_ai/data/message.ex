defmodule ElixirAi.Message do
  import Ecto.Query
  alias ElixirAi.Repo

  def load_for_conversation(conversation_id) do
    Repo.all(
      from m in "messages",
        where: m.conversation_id == ^conversation_id,
        order_by: m.position,
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

  def insert(conversation_id, message, position) do
    Repo.insert_all("messages", [
      [
        id: Ecto.UUID.generate(),
        conversation_id: conversation_id,
        role: to_string(message.role),
        content: message[:content],
        reasoning_content: message[:reasoning_content],
        tool_calls: encode_tool_calls(message[:tool_calls]),
        tool_call_id: message[:tool_call_id],
        position: position,
        inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
      ]
    ])
  end

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(calls), do: Jason.encode!(calls)

  defp decode_message(row) do
    row
    |> Map.update!(:role, &String.to_existing_atom/1)
    |> drop_nil_fields()
  end

  defp drop_nil_fields(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
