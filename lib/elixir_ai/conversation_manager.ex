defmodule ElixirAi.ConversationManager do
  use GenServer
  alias ElixirAi.{Conversation, Message, AiTools}
  import ElixirAi.PubsubTopics, only: [conversation_message_topic: 1]
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
    {:ok, %{conversations: :loading, subscriptions: MapSet.new(), runners: %{}}}
  end

  def create_conversation(name, ai_provider_id, category \\ "user-web", allowed_tools \\ nil) do
    tools = allowed_tools || AiTools.all_tool_names()
    GenServer.call(@name, {:create, name, ai_provider_id, category, tools})
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

  def list_runners do
    GenServer.call(@name, :list_runners)
  end

  def handle_call(message, from, %{conversations: :loading} = state) do
    Logger.warning(
      "Received call #{inspect(message)} from #{inspect(from)} while loading conversations. Retrying after delay."
    )

    Process.send_after(self(), {:retry_call, message, from}, 100)
    {:noreply, state}
  end

  def handle_call(
        {:create, name, ai_provider_id, category, allowed_tools},
        _from,
        %{conversations: conversations} = state
      ) do
    if Map.has_key?(conversations, name) do
      {:reply, {:error, :already_exists}, state}
    else
      case Conversation.create(name, ai_provider_id, category, allowed_tools) do
        :ok ->
          reply_with_started(name, state, fn new_state ->
            %{new_state | conversations: Map.put(new_state.conversations, name, [])}
          end)

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(
        {:open, name},
        _from,
        %{conversations: conversations} = state
      ) do
    if Map.has_key?(conversations, name) do
      reply_with_conversation(name, state)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, %{conversations: conversations} = state) do
    keys = Map.keys(conversations)

    {:reply, keys, state}
  end

  def handle_call({:get_messages, name}, _from, %{conversations: conversations} = state) do
    {:reply, Map.get(conversations, name, []), state}
  end

  def handle_call(:list_runners, _from, state) do
    {:reply, Map.get(state, :runners, %{}), state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runners: runners} = state) do
    runners =
      Enum.reject(runners, fn {_name, info} -> info.pid == pid end)
      |> Map.new()

    Logger.info("ConversationManager: runner #{inspect(pid)} went down (#{inspect(reason)})")
    {:noreply, %{state | runners: runners}}
  end

  def handle_info({:db_error, reason}, state) do
    Logger.error("ConversationManager received db_error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:sql_result_validation_error, error}, state) do
    Logger.error("ConversationManager received sql_result_validation_error: #{inspect(error)}")
    {:noreply, state}
  end

  def handle_info({:store_message, name, message}, %{conversations: conversations} = state) do
    case Conversation.find_id(name) do
      {:ok, conv_id} ->
        Message.insert(conv_id, message, topic: conversation_message_topic(name))

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

  # Returns {pid} to callers that only need to know the process started (e.g. create).
  defp reply_with_started(name, state, update_state) do
    case start_and_subscribe(name, state) do
      {:ok, pid, new_subscriptions, new_runners} ->
        new_state =
          update_state.(%{state | subscriptions: new_subscriptions, runners: new_runners})

        {:reply, {:ok, pid}, new_state}

      {:error, reason} ->
        Logger.error(
          "ConversationManager: failed to start runner for #{name}: #{inspect(reason)}"
        )

        {:reply, {:error, :failed_to_load}, state}
    end
  end

  # Returns the full conversation state using the pid directly, bypassing the
  # Horde registry (which may not have synced yet on the calling node).
  # Also includes the runner pid so the caller can make further direct calls.
  defp reply_with_conversation(name, state) do
    case start_and_subscribe(name, state) do
      {:ok, pid, new_subscriptions, new_runners} ->
        new_state = %{state | subscriptions: new_subscriptions, runners: new_runners}
        conversation = GenServer.call(pid, :get_conversation)
        {:reply, {:ok, Map.put(conversation, :runner_pid, pid)}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp start_and_subscribe(name, state) do
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
          if MapSet.member?(state.subscriptions, name) do
            state.subscriptions
          else
            Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversation_message_topic(name))
            MapSet.put(state.subscriptions, name)
          end

        existing_runners = Map.get(state, :runners, %{})

        new_runners =
          if Map.has_key?(existing_runners, name) do
            existing_runners
          else
            Process.monitor(pid)
            Map.put(existing_runners, name, %{pid: pid, node: node(pid)})
          end

        {:ok, pid, new_subscriptions, new_runners}

      error ->
        error
    end
  end
end
