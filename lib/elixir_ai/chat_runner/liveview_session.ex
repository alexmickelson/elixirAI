defmodule ElixirAi.ChatRunner.LiveviewSession do
  require Logger

  def handle_call(:get_liveview_pids, _from, state) do
    {:reply, Map.keys(state.liveview_pids), state}
  end

  def handle_call(:get_pending_approvals, _from, state) do
    {:reply, ElixirAi.ChatRunner.ApprovalTracker.list(state.pending_approvals), state}
  end

  def handle_call({:register_liveview_pid, liveview_pid}, _from, state) do
    ref = Process.monitor(liveview_pid)
    {:reply, :ok, %{state | liveview_pids: Map.put(state.liveview_pids, liveview_pid, ref)}}
  end

  def handle_call({:register_page_tools, page_tools}, _from, state) do
    {:reply, :ok, %{state | page_tools: page_tools}}
  end

  def handle_call({:deregister_liveview_pid, liveview_pid}, _from, state) do
    case Map.pop(state.liveview_pids, liveview_pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, new_pids} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | liveview_pids: new_pids}}
    end
  end

  def handle_down(ref, pid, _reason, state) do
    case Map.get(state.liveview_pids, pid) do
      ^ref ->
        Logger.info("ChatRunner #{state.name}: LiveView #{inspect(pid)} disconnected")
        {:noreply, %{state | liveview_pids: Map.delete(state.liveview_pids, pid)}}

      _ ->
        {:noreply, state}
    end
  end
end
