defmodule ElixirAi.ChatRunner.ApprovalTracker do
  @moduledoc """
  Pure functions for managing pending tool-approval state inside ChatRunner.

  The `pending_approvals` map has the shape:
    %{ref() => %{pid: pid(), command: String.t(), reason: String.t(), inserted_at: DateTime.t()}}
  """

  def register(approvals, ref, pid, command, reason) do
    Map.put(approvals, ref, %{
      pid: pid,
      command: command,
      reason: reason,
      inserted_at: DateTime.utc_now()
    })
  end

  def resolve(approvals, ref) do
    case Map.pop(approvals, ref) do
      {nil, _} -> {nil, approvals}
      {%{pid: pid}, rest} -> {pid, rest}
    end
  end

  def list(approvals) do
    Enum.map(approvals, fn {ref, data} -> Map.put(data, :ref, ref) end)
  end
end
