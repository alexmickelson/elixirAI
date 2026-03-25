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
    :pg.join(ElixirAi.SingletonPG, {:singleton, __MODULE__}, self())
    # Mitigation 4: receive :nodedown when a cluster peer disappears (sleep/wake, crash)
    :net_kernel.monitor_nodes(true)
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
    # Find the name before removing so we can check for a Horde redistribution replacement
    {name, _} = Enum.find(runners, {nil, nil}, fn {_n, info} -> info.pid == pid end)

    new_runners =
      runners
      |> Enum.reject(fn {_n, info} -> info.pid == pid end)
      |> Map.new()

    Logger.info("ConversationManager: runner #{inspect(pid)} went down (#{inspect(reason)})")

    # Mitigation 2: Horde may have already restarted the runner on another node; re-monitor it
    new_runners =
      if name do
        case :pg.get_members(ElixirAi.RunnerPG, {:runner, name}) do
          [new_pid | _] when new_pid != pid ->
            Logger.info(
              "ConversationManager: re-monitoring redistributed runner for #{name} at #{inspect(new_pid)}"
            )

            Process.monitor(new_pid)
            Map.put(new_runners, name, %{pid: new_pid, node: node(new_pid)})

          _ ->
            new_runners
        end
      else
        new_runners
      end

    {:noreply, %{state | runners: new_runners}}
  end

  # Mitigation 4: node went down — evict all cached runners on that node immediately,
  # before the individual :DOWN messages for each pid arrive.
  def handle_info({:nodedown, down_node}, %{runners: runners} = state) do
    stale = Enum.filter(runners, fn {_name, info} -> info.node == down_node end)

    if stale != [] do
      names = Enum.map(stale, &elem(&1, 0))

      Logger.info(
        "ConversationManager: node #{down_node} down, clearing stale runners: #{inspect(names)}"
      )
    end

    new_runners = Map.reject(runners, fn {_name, info} -> info.node == down_node end)
    {:noreply, %{state | runners: new_runners}}
  end

  def handle_info({:nodeup, _node}, state), do: {:noreply, state}

  def handle_info({:error, {:db_error, reason}}, state) do
    Logger.error("ConversationManager received db_error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:error, {:sql_result_validation_error, error}}, state) do
    Logger.error("ConversationManager received sql_result_validation_error: #{inspect(error)}")
    {:noreply, state}
  end

  def handle_info(
        {:error, {:store_message, name, message}},
        %{conversations: conversations} = state
      ) do
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

    # Mitigation 3: after a ConversationManager restart, re-establish monitors for any
    # ChatRunners that are still alive in Horde — they carry on running but we lost
    # all monitor refs when this process restarted.
    runners =
      :pg.which_groups(ElixirAi.RunnerPG)
      |> Enum.flat_map(fn
        {:runner, name} ->
          case :pg.get_members(ElixirAi.RunnerPG, {:runner, name}) do
            [pid | _] ->
              Process.monitor(pid)
              [{name, %{pid: pid, node: node(pid)}}]

            _ ->
              []
          end

        _ ->
          []
      end)
      |> Map.new()

    Logger.info(
      "ConversationManager: re-established monitors for #{map_size(runners)} live runners"
    )

    {:noreply, %{state | conversations: conversations, runners: runners}}
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
        conversation = GenServer.call(pid, {:conversation, :get_conversation})
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
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          # Mitigation 6: the returned pid may be on a node that just went down but whose
          # :DOWN message hasn't been processed yet; verify the node is still reachable.
          if node_alive?(node(pid)) do
            {:ok, pid}
          else
            # Node is gone; Horde will redistribute — wait briefly for the new registration.
            case registry_lookup_with_retry(name) do
              nil -> {:error, :runner_unavailable}
              new_pid -> {:ok, new_pid}
            end
          end

        # Mitigation 1: :already_present means Horde knows the child spec but the process
        # is mid-redistribution and not yet registered. Retry the registry until it appears.
        {:error, :already_present} ->
          case registry_lookup_with_retry(name) do
            nil -> {:error, :runner_unavailable}
            pid -> {:ok, pid}
          end

        error ->
          error
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

        new_runners =
          case Map.get(state.runners, name) do
            nil ->
              Process.monitor(pid)
              Map.put(state.runners, name, %{pid: pid, node: node(pid)})

            %{pid: ^pid} ->
              # Same pid — nothing to update
              state.runners

            %{pid: old_pid} ->
              # Pid changed (redistribution raced ahead of :DOWN) — swap the monitor
              Process.demonitor(old_pid, [:flush])
              Process.monitor(pid)
              Map.put(state.runners, name, %{pid: pid, node: node(pid)})
          end

        {:ok, pid, new_subscriptions, new_runners}

      error ->
        error
    end
  end

  # Mitigation 5: Horde registry syncs via delta-CRDT with up to ~100ms lag after a
  # process moves nodes. Retry with exponential backoff before concluding it doesn't exist.
  defp registry_lookup_with_retry(name, retries \\ 3, delay_ms \\ 50)
  defp registry_lookup_with_retry(_name, 0, _delay_ms), do: nil

  defp registry_lookup_with_retry(name, retries, delay_ms) do
    case Horde.Registry.lookup(ElixirAi.ChatRegistry, name) do
      [{pid, _} | _] when is_pid(pid) ->
        pid

      _ ->
        Process.sleep(delay_ms)
        registry_lookup_with_retry(name, retries - 1, delay_ms * 2)
    end
  end

  defp node_alive?(n), do: n == Node.self() or n in Node.list()
end
