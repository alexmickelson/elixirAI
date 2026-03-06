defmodule ElixirAi.ConversationManager do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def init(names), do: {:ok, names}

  def create_conversation(name) do
    GenServer.call(__MODULE__, {:create, name})
  end

  def open_conversation(name) do
    GenServer.call(__MODULE__, {:open, name})
  end

  def list_conversations do
    GenServer.call(__MODULE__, :list)
  end

  def handle_call({:create, name}, _from, names) do
    if name in names do
      {:reply, {:error, :already_exists}, names}
    else
      {:reply, start_runner(name), [name | names]}
    end
  end

  def handle_call({:open, name}, _from, names) do
    if name in names do
      {:reply, start_runner(name), names}
    else
      {:reply, {:error, :not_found}, names}
    end
  end
  def handle_call(:list, _from, names) do
    {:reply, names, names}
  end

  defp start_runner(name) do
    case DynamicSupervisor.start_child(
           ElixirAi.ChatRunnerSupervisor,
           {ElixirAi.ChatRunner, name: name}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

end
