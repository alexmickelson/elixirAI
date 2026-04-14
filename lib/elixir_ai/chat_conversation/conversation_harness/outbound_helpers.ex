defmodule ElixirAi.ChatRunner.OutboundHelpers do
  import ElixirAi.PubsubTopics
  alias ElixirAi.Message
  require Logger

  def broadcast_ui(name, msg),
    do:
      Phoenix.PubSub.broadcast(
        ElixirAi.PubSub,
        chat_topic(name),
        {:conversation_stream_message, msg}
      )

  def store_message(conversation_id, name, messages) when is_list(messages) do
    Enum.each(messages, &store_message(conversation_id, name, &1))
  end

  def store_message(nil, name, _message) do
    Logger.error(
      "store_message called with nil conversation_id for #{name} — message will not be persisted"
    )
  end

  def store_message(conversation_id, name, message) do
    topic = conversation_message_topic(name)

    case Message.insert(conversation_id, message, topic: topic) do
      {:error, reason} ->
        Logger.error("Failed to persist message for #{name}: #{inspect(reason)}")
        {:error, reason}

      result ->
        result
    end
  end

  def messages_with_system_prompt(messages, nil), do: messages
  def messages_with_system_prompt(messages, prompt), do: [prompt | messages]
end
