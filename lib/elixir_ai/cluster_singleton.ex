defmodule ElixirAi.ClusterSingleton do
  use GenServer
  require Logger

  @sync_delay_ms 200

  @singletons [ElixirAi.ConversationManager]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    Process.send_after(self(), :start_singletons, @sync_delay_ms)
    {:ok, :pending}
  end

  def handle_info(:start_singletons, _state) do
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

    {:noreply, :started}
  end

  defp singleton_exists?(module) do
    case Horde.Registry.lookup(ElixirAi.ChatRegistry, module) do
      [{pid, _metadata} | _] when is_pid(pid) ->
        true

      _ ->
        false
    end
  end
end
