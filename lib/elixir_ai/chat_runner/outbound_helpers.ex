defmodule ElixirAi.ChatRunner.OutboundHelpers do
  import ElixirAi.PubsubTopics

  def broadcast_ui(name, msg),
    do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, chat_topic(name), msg)

  def store_message(name, messages) when is_list(messages) do
    Enum.each(messages, &store_message(name, &1))
    messages
  end

  def store_message(name, message) do
    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      conversation_message_topic(name),
      {:error, {:store_message, name, message}}
    )

    message
  end
end
