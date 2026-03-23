defmodule ElixirAi.ChatRunner.ErrorHandler do
  require Logger
  import ElixirAi.ChatRunner.OutboundHelpers

  def handle({:db_error, reason}, state) do
    broadcast_ui(state.name, {:db_error, reason})
    {:noreply, state}
  end

  def handle({:sql_result_validation_error, error}, state) do
    Logger.error("ChatRunner received sql_result_validation_error: #{inspect(error)}")
    broadcast_ui(state.name, {:db_error, "Schema validation error: #{inspect(error)}"})
    {:noreply, state}
  end

  def handle({:store_message, _name, _message}, state) do
    {:noreply, state}
  end
end
