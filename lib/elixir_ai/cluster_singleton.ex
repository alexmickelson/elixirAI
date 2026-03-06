defmodule ElixirAi.ClusterSingleton do
  use GenServer

  @sync_delay_ms 200

  @singletons [ElixirAi.ConversationManager]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :start_singletons, @sync_delay_ms)
    {:ok, :pending}
  end

  @impl true
  def handle_info(:start_singletons, state) do
    for module <- @singletons do
      case Horde.DynamicSupervisor.start_child(ElixirAi.ChatRunnerSupervisor, module) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
        {:error, reason} ->
          require Logger
          Logger.warning("ClusterSingleton: failed to start #{inspect(module)}: #{inspect(reason)}")
      end
    end

    {:noreply, :started}
  end
end
