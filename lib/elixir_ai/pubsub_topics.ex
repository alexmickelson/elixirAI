defmodule ElixirAi.PubsubTopics do
  def conversation_message_topic(name), do: "conversation_messages:#{name}"
  def chat_topic(name), do: "ai_chat:#{name}"
  def providers_topic, do: "providers"
  def admin_topic, do: "admin"
end
