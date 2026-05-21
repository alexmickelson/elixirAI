defmodule ElixirAi.ChatRunner.ApprovalTracker do
  @moduledoc """
  Pure functions for managing pending tool-approval state inside ChatRunner.

  The `pending_approvals` map has the shape:
    %{ref() => %{
        current_message_id: term(),
        tool_call_id: String.t(),
        command: String.t(),
        reason: String.t(),
        inserted_at: DateTime.t()
      }}

  No process pid is stored — approval state is data only. The server handles
  execution or denial directly when the user decides.
  """

  def register(approvals, ref, current_message_id, tool_call_id, command, reason) do
    Map.put(approvals, ref, %{
      current_message_id: current_message_id,
      tool_call_id: tool_call_id,
      command: command,
      reason: reason,
      inserted_at: DateTime.utc_now()
    })
  end

  def resolve(approvals, ref) do
    case Map.pop(approvals, ref) do
      {nil, _} -> {nil, approvals}
      {context, rest} -> {context, rest}
    end
  end

  def list(approvals) do
    Enum.map(approvals, fn {ref, data} -> Map.put(data, :ref, ref) end)
  end
end
