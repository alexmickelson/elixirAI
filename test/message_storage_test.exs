defmodule ElixirAi.MessageStorageTest do
  use ElixirAi.TestCase
  import ElixirAi.TestCase, only: [start_test_conversation: 1]

  setup do
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

        String.contains?(sql, "FROM text_messages") and not String.contains?(sql, "INSERT") ->
          # Load text messages query
          []

        String.contains?(sql, "FROM tool_calls_request_messages") and
            not String.contains?(sql, "INSERT") ->
          # Load tool calls query
          []

        String.contains?(sql, "FROM tool_response_messages") and
            not String.contains?(sql, "INSERT") ->
          # Load tool responses query
          []

        String.contains?(sql, "INSERT INTO text_messages") and
            String.contains?(sql, "RETURNING id") ->
          # Assistant message insert - return a fake message_id
          send(test_pid, {:insert_assistant_message, params})
          [%{"id" => 123}]

        String.contains?(sql, "INSERT INTO text_messages") ->
          # User message insert
          send(test_pid, {:insert_message, params})
          []

        String.contains?(sql, "INSERT INTO tool_calls_request_messages") ->
          send(test_pid, {:insert_tool_call, params})
          []

        String.contains?(sql, "INSERT INTO tool_response_messages") ->
          send(test_pid, {:insert_tool_response, params})
          []

        true ->
          []
      end
    end)

    # 4-arity version used by Conversation.all_names/0
    stub(ElixirAi.Data.DbHelpers, :run_sql, fn _sql, _params, _topic, _schema -> [] end)

    %{conv_name: conv_name} = start_test_conversation(conv_name)
    conv_name
  end

  test "run_sql is called with user message params" do
    conv_name = setup_conversation()

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

    ElixirAi.ChatRunner.new_user_message(conv_name, "hello world")

    assert_receive {:insert_message, params}, 2000
    assert params["role"] == "user"
    assert params["content"] == "hello world"
  end

  test "run_sql is called with assistant message params" do
    conv_name = setup_conversation()

    stub(ElixirAi.ChatUtils, :request_ai_response, fn server, _messages, _tools, _provider ->
      id = make_ref()
      send(server, {:stream, {:start_new_ai_response, id}})
      send(server, {:stream, {:ai_text_chunk, id, "Hello from AI"}})
      send(server, {:stream, {:ai_text_stream_finish, id}})
      :ok
    end)

    stub(ElixirAi.ChatUtils, :request_ai_response, fn server,
                                                      _messages,
                                                      _tools,
                                                      _provider,
                                                      _tool_choice ->
      id = make_ref()
      send(server, {:stream, {:start_new_ai_response, id}})
      send(server, {:stream, {:ai_text_chunk, id, "Hello from AI"}})
      send(server, {:stream, {:ai_text_stream_finish, id}})
      :ok
    end)

    ElixirAi.ChatRunner.new_user_message(conv_name, "hi")

    assert_receive {:insert_message, %{"role" => "user"}}, 2000
    assert_receive {:insert_assistant_message, params}, 2000
    assert params["role"] == "assistant"
    assert params["content"] == "Hello from AI"
  end

  test "run_sql is called with tool request and tool result message params" do
    conv_name = setup_conversation()

    # First AI call triggers the tool; subsequent calls (after tool completes) are no-ops.
    expect(ElixirAi.ChatUtils, :request_ai_response, fn server,
                                                        _messages,
                                                        _tools,
                                                        _provider,
                                                        _tool_choice ->
      id = make_ref()
      send(server, {:stream, {:start_new_ai_response, id}})

      send(
        server,
        {:stream,
         {:ai_tool_call_start, id, {"store_thing", ~s({"name":"k","value":"v"}), 0, "tc_1"}}}
      )

      send(server, {:stream, {:ai_tool_call_end, id}})
      :ok
    end)

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

    ElixirAi.ChatRunner.new_user_message(conv_name, "store something")

    assert_receive {:insert_message, %{"role" => "user"}}, 2000

    # Assistant message with tool_calls
    assert_receive {:insert_assistant_message, params}, 2000
    assert params["role"] == "assistant"

    # Tool call details stored separately
    assert_receive {:insert_tool_call, params}, 2000
    assert params["tool_name"] == "store_thing"
    assert params["tool_call_id"] == "tc_1"

    # Tool result stored in tool_responses table
    assert_receive {:insert_tool_response, params}, 2000
    assert params["tool_call_id"] == "tc_1"
  end
end
