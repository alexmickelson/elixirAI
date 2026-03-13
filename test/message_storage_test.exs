defmodule ElixirAi.MessageStorageTest do
  use ElixirAi.TestCase

  setup do
    # Default run_sql and request_ai_response stubs are set by TestCase.
    # Start ConversationManager AFTER stubs are active so its :load_conversations
    # handler sees the stub rather than hitting the real (absent) DB.
    case Horde.DynamicSupervisor.start_child(
           ElixirAi.ChatRunnerSupervisor,
           ElixirAi.ConversationManager
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> :ok
    end

    :ok
  end

  # Stubs run_sql for all infrastructure calls (conversation lookup, message load,
  # conversation insert) and notifies the test pid whenever a message INSERT occurs.
  defp setup_conversation do
    conv_name = "test_conv_#{System.unique_integer([:positive])}"
    conv_id = :crypto.strong_rand_bytes(16)
    test_pid = self()

    stub(ElixirAi.Data.DbHelpers, :run_sql, fn sql, params, _topic ->
      cond do
        String.contains?(sql, "SELECT id FROM conversations") ->
          [%{"id" => conv_id}]

        String.contains?(sql, "INSERT INTO messages") ->
          send(test_pid, {:insert_message, params})
          []

        true ->
          []
      end
    end)

    # 4-arity version used by Conversation.all_names/0
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic, _schema -> [] end)

    provider_id = Ecto.UUID.generate()
    {:ok, _pid} = ElixirAi.ConversationManager.create_conversation(conv_name, provider_id)
    conv_name
  end

  test "run_sql is called with user message params" do
    conv_name = setup_conversation()
    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server, _messages, _tools -> :ok end)

    ElixirAi.ChatRunner.new_user_message(conv_name, "hello world")

    assert_receive {:insert_message, params}, 2000
    assert params["role"] == "user"
    assert params["content"] == "hello world"
  end

  test "run_sql is called with assistant message params" do
    conv_name = setup_conversation()

    stub(ElixirAi.ChatUtils, :request_ai_response, fn server, _messages, _tools ->
      id = make_ref()
      send(server, {:start_new_ai_response, id})
      send(server, {:ai_text_chunk, id, "Hello from AI"})
      send(server, {:ai_text_stream_finish, id})
      :ok
    end)

    ElixirAi.ChatRunner.new_user_message(conv_name, "hi")

    assert_receive {:insert_message, %{"role" => "user"}}, 2000
    assert_receive {:insert_message, params}, 2000
    assert params["role"] == "assistant"
    assert params["content"] == "Hello from AI"
  end

  test "run_sql is called with tool request and tool result message params" do
    conv_name = setup_conversation()

    # First AI call triggers the tool; subsequent calls (after tool completes) are no-ops.
    expect(ElixirAi.ChatUtils, :request_ai_response, fn server, _messages, _tools ->
      id = make_ref()
      send(server, {:start_new_ai_response, id})

      send(
        server,
        {:ai_tool_call_start, id, {"store_thing", ~s({"name":"k","value":"v"}), 0, "tc_1"}}
      )

      send(server, {:ai_tool_call_end, id})
      :ok
    end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn _server, _messages, _tools -> :ok end)

    ElixirAi.ChatRunner.new_user_message(conv_name, "store something")

    assert_receive {:insert_message, %{"role" => "user"}}, 2000

    # Assistant message that carries the tool_calls list
    assert_receive {:insert_message, params}, 2000
    assert params["role"] == "assistant"
    refute is_nil(params["tool_calls"])

    # Tool result message
    assert_receive {:insert_message, params}, 2000
    assert params["role"] == "tool"
    assert params["tool_call_id"] == "tc_1"
  end
end
