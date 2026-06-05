defmodule ElixirAi.ChatRunner.ErrorHandler do
  require Logger
  import ElixirAi.ChatRunner.OutboundHelpers

  def handle({:db_error, reason}, state) do
    broadcast_ui(state.name, {:db_error, reason})
    {:noreply, state}
  end

  def handle({:sandbox_error, reason}, state) do
    if is_binary(reason) and reason != "" do
      Logger.error("ChatRunner sandbox error for #{state.name}: #{reason}")
    end

    broadcast_ui(state.name, {:sandbox_error, reason})
    {:noreply, %{state | sandbox_error: reason}}
  end

  def handle({:sql_result_validation_error, error}, state) do
    Logger.error("ChatRunner received sql_result_validation_error: #{inspect(error)}")
    broadcast_ui(state.name, {:db_error, "Schema validation error: #{inspect(error)}"})
    {:noreply, state}
  end
end
