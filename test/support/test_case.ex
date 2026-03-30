defmodule ElixirAi.TestCase do
  use ExUnit.CaseTemplate
  use Mimic

  using do
    quote do
      use Mimic
    end
  end

  setup :set_mimic_global

  setup do
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic -> [] end)
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic, _schema -> [] end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server, _messages, _tools, _provider ->
      :ok
    end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server,
                                                      _messages,
                                                      _tools,
                                                      _provider,
                                                      _tool_choice ->
      :ok
    end)

    :ok
  end

  def start_test_conversation(name \\ nil, provider_id \\ nil) do
    conv_name = name || "test_conv_#{System.unique_integer([:positive])}"
    provider_id = provider_id || Ecto.UUID.generate()

    case Horde.DynamicSupervisor.start_child(
           ElixirAi.ChatRunnerSupervisor,
           ElixirAi.ConversationManager
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
    end

    {:ok, pid} = ElixirAi.ConversationManager.create_conversation(conv_name, provider_id)

    # Synchronous call ensures handle_continue(:load_from_db) has completed
    _ = ElixirAi.ChatRunner.get_conversation(conv_name)

    %{conv_name: conv_name, runner_pid: pid}
  end
end
