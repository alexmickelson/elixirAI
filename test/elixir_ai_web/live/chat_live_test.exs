defmodule ElixirAiWeb.ChatLiveTest do
  use ElixirAiWeb.ConnCase, async: false
  import ElixirAi.PubsubTopics, only: [chat_topic: 1]
  import ElixirAi.TestCase, only: [start_test_conversation: 1]

  setup do
    %{runner_pid: pid} = start_test_conversation("test_conv")

    stub(ElixirAi.ConversationManager, :open_conversation, fn _name ->
      {:ok, %{runner_pid: pid}}
    end)

    :ok
  end

  test "displays a db error when a db_error message is broadcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat/test_conv")

    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      chat_topic("test_conv"),
      {:conversation_stream_message, {:db_error, "unique constraint violated"}}
    )

    assert render(view) =~ "unique constraint violated"
  end
end
