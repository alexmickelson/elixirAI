defmodule ElixirAiWeb.ChatLiveTest do
  use ElixirAiWeb.ConnCase, async: false
  import ElixirAi.PubsubTopics, only: [conversation_message_topic: 1]

  setup do
    stub(ElixirAi.ConversationManager, :open_conversation, fn _name -> {:ok, self()} end)

    stub(ElixirAi.ChatRunner, :get_conversation, fn _name ->
      %{messages: [], streaming_response: nil}
    end)

    :ok
  end

  test "displays a db error when a db_error message is broadcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat/test_conv")

    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      conversation_message_topic("test_conv"),
      {:db_error, "unique constraint violated"}
    )

    assert render(view) =~ "unique constraint violated"
  end
end
