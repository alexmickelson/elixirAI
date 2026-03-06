defmodule ElixirAi.ConversationManager do
  use GenServer
  alias ElixirAi.{Conversation, Message}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    names = Conversation.all_names()
    conversations = Map.new(names, fn name -> {name, []} end)
    {:ok, conversations}
  end

  def create_conversation(name) do
    GenServer.call(__MODULE__, {:create, name})
  end

  def open_conversation(name) do
    GenServer.call(__MODULE__, {:open, name})
  end

  def list_conversations do
    GenServer.call(__MODULE__, :list)
  end

  def get_messages(name) do
    GenServer.call(__MODULE__, {:get_messages, name})
  end

  def handle_call({:create, name}, _from, conversations) do
    if Map.has_key?(conversations, name) do
      {:reply, {:error, :already_exists}, conversations}
    else
      case Conversation.create(name) do
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
    {:reply, Map.keys(conversations), conversations}
  end

  def handle_call({:get_messages, name}, _from, conversations) do
    {:reply, Map.get(conversations, name, []), conversations}
  end

  def handle_info({:store_message, name, message}, conversations) do
    messages = Map.get(conversations, name, [])
    position = length(messages)

    case Conversation.find_id(name) do
      {:ok, conv_id} -> Message.insert(conv_id, message, position)
      _ -> :ok
    end

    {:noreply, Map.update(conversations, name, [message], &(&1 ++ [message]))}
  end

  defp start_and_subscribe(name) do
    result =
      case DynamicSupervisor.start_child(
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
