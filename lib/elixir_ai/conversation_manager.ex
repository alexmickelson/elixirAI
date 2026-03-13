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
    send(self(), :load_conversations)
    {:ok, %{conversations: :loading, subscriptions: MapSet.new()}}
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

  def handle_call(message, from, %{conversations: :loading} = state) do
    Logger.warning(
      "Received call #{inspect(message)} from #{inspect(from)} while loading conversations. Retrying after delay."
    )

    Process.send_after(self(), {:retry_call, message, from}, 100)
    {:noreply, state}
  end

  def handle_call(
        {:create, name, ai_provider_id},
        _from,
        %{conversations: conversations, subscriptions: subscriptions} = state
      ) do
    if Map.has_key?(conversations, name) do
      {:reply, {:error, :already_exists}, state}
    else
      case Conversation.create(name, ai_provider_id) do
        :ok ->
          case start_and_subscribe(name, subscriptions) do
            {:ok, pid, new_subscriptions} ->
              {:reply, {:ok, pid},
               %{
                 state
                 | conversations: Map.put(conversations, name, []),
                   subscriptions: new_subscriptions
               }}

            {:error, _reason} = error ->
              {:reply, error, state}
          end

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(
        {:open, name},
        _from,
        %{conversations: conversations, subscriptions: subscriptions} = state
      ) do
    if Map.has_key?(conversations, name) do
      case start_and_subscribe(name, subscriptions) do
        {:ok, pid, new_subscriptions} ->
          {:reply, {:ok, pid}, %{state | subscriptions: new_subscriptions}}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, %{conversations: conversations} = state) do
    keys = Map.keys(conversations)

    Logger.debug(
      "list_conversations returning: #{inspect(keys, limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)}"
    )

    {:reply, keys, state}
  end

  def handle_call({:get_messages, name}, _from, %{conversations: conversations} = state) do
    {:reply, Map.get(conversations, name, []), state}
  end

  def handle_info({:store_message, name, message}, %{conversations: conversations} = state) do
    case Conversation.find_id(name) do
      {:ok, conv_id} ->
        Message.insert(conv_id, message, topic: ElixirAi.ChatRunner.message_topic(name))

      _ ->
        :ok
    end

    {:noreply,
     %{state | conversations: Map.update(conversations, name, [message], &(&1 ++ [message]))}}
  end

  def handle_info(:load_conversations, state) do
    conversation_list = Conversation.all_names()
    Logger.info("Loaded #{length(conversation_list)} conversations from DB")

    conversations = Map.new(conversation_list, fn %{name: name} -> {name, []} end)
    Logger.info("Conversation map keys: #{inspect(Map.keys(conversations))}")
    {:noreply, %{state | conversations: conversations}}
  end

  def handle_info({:retry_call, message, from}, state) do
    case handle_call(message, from, state) do
      {:reply, reply, new_state} ->
        GenServer.reply(from, reply)
        {:noreply, new_state}

      {:noreply, new_state} ->
        {:noreply, new_state}
    end
  end

  defp start_and_subscribe(name, subscriptions) do
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
      {:ok, pid} ->
        new_subscriptions =
          if MapSet.member?(subscriptions, name) do
            subscriptions
          else
            Phoenix.PubSub.subscribe(ElixirAi.PubSub, ElixirAi.ChatRunner.message_topic(name))
            MapSet.put(subscriptions, name)
          end

        {:ok, pid, new_subscriptions}

      error ->
        error
    end
  end
end
