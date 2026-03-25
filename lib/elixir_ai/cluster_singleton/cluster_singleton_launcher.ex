defmodule ElixirAi.ClusterSingletonLauncher do
  require Logger

  @retry_delay_ms 500

  def start_link(opts) do
    Task.start_link(fn -> run(opts) end)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :module)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  # Returns [{module, node_or_nil}] for all configured singletons.
  # node_or_nil is nil when the singleton is not currently running anywhere.
  def singleton_locations do
    [ElixirAi.ConversationManager]
    |> Enum.map(fn module ->
      node =
        case :pg.get_members(ElixirAi.SingletonPG, {:singleton, module}) do
          [pid | _] -> node(pid)
          _ -> nil
        end

      {module, node}
    end)
  end

  defp run(opts) do
    module = Keyword.fetch!(opts, :module)

    if Node.list() == [] do
      Logger.debug(
        "ClusterSingletonLauncher: no peer nodes yet, retrying in #{@retry_delay_ms}ms"
      )

      Process.sleep(@retry_delay_ms)
      run(opts)
    else
      launch(module)
    end
  end

  defp launch(module) do
    if singleton_exists?(module) do
      Logger.debug(
        "ClusterSingletonLauncher: singleton already exists, skipping start for #{inspect(module)}"
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
            "ClusterSingletonLauncher: failed to start #{inspect(module)}: #{inspect(reason)}"
          )
      end
    end
  end

  defp singleton_exists?(module) do
    case Horde.Registry.lookup(ElixirAi.ChatRegistry, module) do
      [{pid, _metadata} | _] when is_pid(pid) -> true
      _ -> false
    end
  end
end
