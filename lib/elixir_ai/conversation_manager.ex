defmodule ElixirAi.ConversationManager do
  use GenServer
  alias ElixirAi.{Conversation, Message}
  require Logger

  @name {:via, Horde.Registry, {ElixirAi.ChatRegistry, __MODULE__}}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def init(_) do
    Logger.info("ConversationManager initializing...")
    conversation_list = Conversation.all_names()
    Logger.info("Loaded #{length(conversation_list)} conversations from DB")

    # Log each conversation and check for UTF-8 issues
    Enum.each(conversation_list, fn conv ->
      Logger.info(
        "Conversation: #{inspect(conv, limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)}"
      )
    end)

    conversations = Map.new(conversation_list, fn %{name: name} -> {name, []} end)
    Logger.info("Conversation map keys: #{inspect(Map.keys(conversations))}")
    {:ok, conversations}
  end

  def create_conversation(name, ai_provider_id) do
    GenServer.call(@name, {:create, name, ai_provider_id})
  end

  def open_conversation(name) do
    GenServer.call(@name, {:open, name})
  end

  def list_conversations do
    GenServer.call(@name, :list)
  end

  def get_messages(name) do
    GenServer.call(@name, {:get_messages, name})
  end

  def handle_call({:create, name, ai_provider_id}, _from, conversations) do
    if Map.has_key?(conversations, name) do
      {:reply, {:error, :already_exists}, conversations}
    else
      case Conversation.create(name, ai_provider_id) do
        :ok ->
          case start_and_subscribe(name) do
            {:ok, _pid} = ok -> {:reply, ok, Map.put(conversations, name, [])}
            error -> {:reply, error, conversations}
          end

        {:error, _} = error ->
          {:reply, error, conversations}
      end
    end
  end

  def handle_call({:open, name}, _from, conversations) do
    if Map.has_key?(conversations, name) do
      case start_and_subscribe(name) do
        {:ok, _pid} = ok -> {:reply, ok, conversations}
        error -> {:reply, error, conversations}
      end
    else
      {:reply, {:error, :not_found}, conversations}
    end
  end

  def handle_call(:list, _from, conversations) do
    keys = Map.keys(conversations)

    Logger.debug(
      "list_conversations returning: #{inspect(keys, limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)}"
    )

    {:reply, keys, conversations}
  end

  def handle_call({:get_messages, name}, _from, conversations) do
    {:reply, Map.get(conversations, name, []), conversations}
  end

  def handle_info({:store_message, name, message}, conversations) do
    case Conversation.find_id(name) do
      {:ok, conv_id} -> Message.insert(conv_id, message)
      _ -> :ok
    end

    {:noreply, Map.update(conversations, name, [message], &(&1 ++ [message]))}
  end

  defp start_and_subscribe(name) do
    result =
      case Horde.DynamicSupervisor.start_child(
             ElixirAi.ChatRunnerSupervisor,
             {ElixirAi.ChatRunner, name: name}
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        error -> error
      end

    case result do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(ElixirAi.PubSub, "conversation_messages:#{name}")
        result

      _ ->
        result
    end
  end
end
