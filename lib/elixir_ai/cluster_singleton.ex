defmodule ElixirAi.ClusterSingleton do
  use GenServer
  require Logger

  @sync_delay_ms 200
  @retry_delay_ms 500

  @singletons [ElixirAi.ConversationManager]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  def configured_singletons, do: @singletons

  def init(_opts) do
    Process.send_after(self(), :start_singletons, @sync_delay_ms)
    {:ok, :pending}
  end

  def handle_info(:start_singletons, state) do
    if Node.list() == [] do
      Logger.debug("ClusterSingleton: no peer nodes yet, retrying in #{@retry_delay_ms}ms")
      Process.send_after(self(), :start_singletons, @retry_delay_ms)
      {:noreply, state}
    else
      start_singletons()
      {:noreply, :started}
    end
  end

  defp start_singletons do
    for module <- @singletons do
      if singleton_exists?(module) do
        Logger.debug(
          "ClusterSingleton: singleton already exists, skipping start for #{inspect(module)}"
        )
      else
        case Horde.DynamicSupervisor.start_child(ElixirAi.ChatRunnerSupervisor, module) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :already_present} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "ClusterSingleton: failed to start #{inspect(module)}: #{inspect(reason)}"
            )
        end
      end
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state, state}

  defp singleton_exists?(module) do
    case Horde.Registry.lookup(ElixirAi.ChatRegistry, module) do
      [{pid, _metadata} | _] when is_pid(pid) ->
        true

      _ ->
        false
    end
  end
end
