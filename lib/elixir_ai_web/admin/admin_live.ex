defmodule ElixirAiWeb.AdminLive do
  use ElixirAiWeb, :live_view
  require Logger

  @refresh_ms 1_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :net_kernel.monitor_nodes(true)
      :pg.join(ElixirAi.LiveViewPG, {:liveview, __MODULE__}, self())
      schedule_refresh()
    end

    {:ok, assign(socket, cluster_info: gather_info())}
  end

  def handle_info({:nodeup, _node}, socket) do
    {:noreply, assign(socket, cluster_info: gather_info())}
  end

  def handle_info({:nodedown, _node}, socket) do
    {:noreply, assign(socket, cluster_info: gather_info())}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, cluster_info: gather_info())}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp gather_info do
    import ElixirAi.PubsubTopics

    all_nodes = [Node.self() | Node.list()]
    configured = ElixirAi.ClusterSingleton.configured_singletons()

    node_statuses =
      Enum.map(all_nodes, fn node ->
        status =
          if node == Node.self() do
            try do
              ElixirAi.ClusterSingleton.status()
            catch
              _, _ -> :unreachable
            end
          else
            case :rpc.call(node, ElixirAi.ClusterSingleton, :status, [], 3_000) do
              {:badrpc, _} -> :unreachable
              result -> result
            end
          end

        {node, status}
      end)

    singleton_locations =
      Enum.map(configured, fn module ->
        location =
          case Horde.Registry.lookup(ElixirAi.ChatRegistry, module) do
            [{pid, _}] -> node(pid)
            _ -> nil
          end

        {module, location}
      end)

    # All ChatRunner entries in the distributed registry, keyed by conversation name.
    # Each entry is a {name, node, pid, supervisor_node} tuple.
    chat_runners =
      Horde.DynamicSupervisor.which_children(ElixirAi.ChatRunnerSupervisor)
      |> Enum.flat_map(fn
        {_, pid, _, _} when is_pid(pid) ->
          case Horde.Registry.select(ElixirAi.ChatRegistry, [
                 {{:"$1", pid, :"$2"}, [], [{{:"$1", pid, :"$2"}}]}
               ]) do
            [{name, ^pid, _}] when is_binary(name) -> [{name, node(pid), pid}]
            _ -> []
          end

        _ ->
          []
      end)
      |> Enum.sort_by(&elem(&1, 0))

    # :pg is cluster-wide — one local call returns members from all nodes.
    # Processes are automatically removed from their group when they die.
    liveviews =
      :pg.which_groups(ElixirAi.LiveViewPG)
      |> Enum.flat_map(fn
        {:liveview, view} ->
          :pg.get_members(ElixirAi.LiveViewPG, {:liveview, view})
          |> Enum.map(fn pid -> {view, node(pid)} end)

        _ ->
          []
      end)

    %{
      nodes: node_statuses,
      configured_singletons: configured,
      singleton_locations: singleton_locations,
      chat_runners: chat_runners,
      liveviews: liveviews
    }
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <h1 class="text-lg font-semibold text-cyan-200 tracking-wide">Cluster Admin</h1>

      <div class="grid gap-4 grid-cols-1 lg:grid-cols-2 xl:grid-cols-3">
        <%= for {node, status} <- @cluster_info.nodes do %>
          <% node_singletons =
            Enum.filter(@cluster_info.singleton_locations, fn {_, loc} -> loc == node end) %>
          <% node_runners =
            Enum.filter(@cluster_info.chat_runners, fn {_, rnode, _} -> rnode == node end) %>
          <% node_liveviews =
            @cluster_info.liveviews
            |> Enum.filter(fn {_, n} -> n == node end)
            |> Enum.group_by(fn {view, _} -> view end) %>

          <div class="rounded-lg border border-cyan-800/50 bg-cyan-950/30 overflow-hidden">
            <div class="flex items-center justify-between px-4 py-3 bg-cyan-900/40 border-b border-cyan-800/50">
              <div class="flex items-center gap-2">
                <span class="font-mono text-sm font-semibold text-cyan-200">{node}</span>
                <%= if node == Node.self() do %>
                  <span class="text-xs bg-cyan-800/50 text-cyan-400 px-1.5 py-0.5 rounded">self</span>
                <% end %>
              </div>
              <.status_badge status={status} />
            </div>

            <div class="p-4 space-y-4">
              <%= if node_singletons != [] do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-cyan-600 mb-1.5">
                    Singletons
                  </p>
                  <div class="space-y-1">
                    <%= for {module, _} <- node_singletons do %>
                      <div class="px-2 py-1.5 rounded bg-cyan-900/30 font-mono text-xs text-cyan-300">
                        {inspect(module)}
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_runners != [] do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-cyan-600 mb-1.5">
                    Chat Runners
                    <span class="normal-case font-normal text-cyan-700 ml-1">
                      {length(node_runners)}
                    </span>
                  </p>
                  <div class="space-y-1">
                    <%= for {name, _, _} <- node_runners do %>
                      <div class="px-2 py-1.5 rounded bg-cyan-900/30 font-mono text-xs text-cyan-200">
                        {name}
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_liveviews != %{} do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-cyan-600 mb-1.5">
                    LiveViews
                  </p>
                  <div class="space-y-1">
                    <%= for {view, instances} <- node_liveviews do %>
                      <div class="px-2 py-1.5 rounded bg-cyan-900/30 flex justify-between items-center gap-2">
                        <span class="font-mono text-xs text-cyan-200">{short_module(view)}</span>
                        <span class="text-xs text-cyan-600">×{length(instances)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_singletons == [] and node_runners == [] and node_liveviews == %{} do %>
                <p class="text-xs text-cyan-700 italic">No active processes</p>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <% unlocated =
        Enum.filter(@cluster_info.singleton_locations, fn {_, loc} -> is_nil(loc) end) %>
      <%= if unlocated != [] do %>
        <section>
          <h2 class="text-xs font-semibold uppercase tracking-widest text-red-500 mb-2">
            Singletons Not Running
          </h2>
          <div class="flex flex-wrap gap-2">
            <%= for {module, _} <- unlocated do %>
              <span class="px-2 py-1 rounded bg-red-900/20 border border-red-800/40 font-mono text-xs text-red-400">
                {inspect(module)}
              </span>
            <% end %>
          </div>
        </section>
      <% end %>

      <p class="text-xs text-cyan-800">Refreshes every 1s or on node events.</p>
    </div>
    """
  end

  defp short_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> List.last()
  end

  defp status_badge(assigns) do
    ~H"""
    <%= case @status do %>
      <% :started -> %>
        <span class="inline-block px-2 py-0.5 rounded text-xs font-semibold bg-green-900 text-green-300">
          started
        </span>
      <% :pending -> %>
        <span class="inline-block px-2 py-0.5 rounded text-xs font-semibold bg-yellow-900 text-yellow-300">
          pending
        </span>
      <% :unreachable -> %>
        <span class="inline-block px-2 py-0.5 rounded text-xs font-semibold bg-red-900 text-red-300">
          unreachable
        </span>
      <% other -> %>
        <span class="inline-block px-2 py-0.5 rounded text-xs font-semibold bg-cyan-900 text-cyan-300">
          {inspect(other)}
        </span>
    <% end %>
    """
  end
end
