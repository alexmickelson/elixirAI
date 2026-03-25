defmodule ElixirAiWeb.AdminLive do
  import ElixirAi.PubsubTopics
  use ElixirAiWeb, :live_view
  require Logger

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        :net_kernel.monitor_nodes(true)
        # Join before monitoring so our own join doesn't trigger a spurious refresh.
        :pg.join(ElixirAi.LiveViewPG, {:liveview, __MODULE__}, self())
        {pg_ref, _} = :pg.monitor_scope(ElixirAi.LiveViewPG)
        {runner_pg_ref, _} = :pg.monitor_scope(ElixirAi.RunnerPG)
        {singleton_pg_ref, _} = :pg.monitor_scope(ElixirAi.SingletonPG)

        socket
        |> assign(pg_ref: pg_ref)
        |> assign(runner_pg_ref: runner_pg_ref)
        |> assign(singleton_pg_ref: singleton_pg_ref)
      else
        assign(socket, pg_ref: nil, runner_pg_ref: nil, singleton_pg_ref: nil)
      end

    {:ok,
     socket
     |> assign(nodes: gather_node_statuses())
     |> assign(singleton_locations: gather_singleton_locations())
     |> assign(chat_runners: gather_chat_runners())
     |> assign(liveviews: gather_liveviews())}
  end

  def handle_info({:nodeup, _node}, socket) do
    {:noreply, assign(socket, nodes: gather_node_statuses())}
  end

  def handle_info({:nodedown, _node}, socket) do
    {:noreply, assign(socket, nodes: gather_node_statuses())}
  end

  def handle_info(:refresh_singletons, socket) do
    {:noreply, assign(socket, singleton_locations: gather_singleton_locations())}
  end

  def handle_info({ref, change, _group, _pids}, %{assigns: %{singleton_pg_ref: ref}} = socket)
      when is_reference(ref) and change in [:join, :leave] do
    {:noreply, assign(socket, singleton_locations: gather_singleton_locations())}
  end

  def handle_info({ref, change, _group, _pids}, %{assigns: %{pg_ref: ref}} = socket)
      when is_reference(ref) and change in [:join, :leave] do
    {:noreply, assign(socket, liveviews: gather_liveviews())}
  end

  def handle_info({ref, change, _group, _pids}, %{assigns: %{runner_pg_ref: ref}} = socket)
      when is_reference(ref) and change in [:join, :leave] do
    {:noreply, assign(socket, chat_runners: gather_chat_runners())}
  end

  defp gather_node_statuses do
    all_nodes = [Node.self() | Node.list()]

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
  end

  defp gather_singleton_locations do
    running =
      :pg.which_groups(ElixirAi.SingletonPG)
      |> Enum.flat_map(fn
        {:singleton, module} ->
          case :pg.get_members(ElixirAi.SingletonPG, {:singleton, module}) do
            [pid | _] -> [{module, node(pid)}]
            _ -> []
          end

        _ ->
          []
      end)
      |> Map.new()

    ElixirAi.ClusterSingleton.configured_singletons()
    |> Enum.map(fn module -> {module, Map.get(running, module)} end)
  end

  # All ChatRunner entries via :pg membership, keyed by conversation name.
  # Each entry is a {name, node, pid} tuple.
  defp gather_chat_runners do
    :pg.which_groups(ElixirAi.RunnerPG)
    |> Enum.flat_map(fn
      {:runner, name} ->
        :pg.get_members(ElixirAi.RunnerPG, {:runner, name})
        |> Enum.map(fn pid -> {name, node(pid), pid} end)

      _ ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # :pg is cluster-wide — one local call returns members from all nodes.
  # Processes are automatically removed from their group when they die.
  defp gather_liveviews do
    :pg.which_groups(ElixirAi.LiveViewPG)
    |> Enum.flat_map(fn
      {:liveview, view} ->
        :pg.get_members(ElixirAi.LiveViewPG, {:liveview, view})
        |> Enum.map(fn pid -> {view, node(pid)} end)

      _ ->
        []
    end)
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <h1 class="text-lg font-semibold text-seafoam-200 tracking-wide">Cluster Admin</h1>

      <div class="grid gap-4 grid-cols-1 lg:grid-cols-2 xl:grid-cols-3">
        <%= for {node, status} <- @nodes do %>
          <% node_singletons =
            Enum.filter(@singleton_locations, fn {_, loc} -> loc == node end) %>
          <% node_runners =
            Enum.filter(@chat_runners, fn {_, rnode, _} -> rnode == node end) %>
          <% node_liveviews =
            @liveviews
            |> Enum.filter(fn {_, n} -> n == node end)
            |> Enum.group_by(fn {view, _} -> view end) %>

          <div class="rounded-lg border border-seafoam-800/50 bg-seafoam-950/30 overflow-hidden">
            <div class="flex items-center justify-between px-4 py-3 bg-seafoam-900/40 border-b border-seafoam-800/50">
              <div class="flex items-center gap-2">
                <span class="font-mono text-sm font-semibold text-seafoam-200">{node}</span>
                <%= if node == Node.self() do %>
                  <span class="text-xs bg-seafoam-800/50 text-seafoam-400 px-1.5 py-0.5 rounded">
                    self
                  </span>
                <% end %>
              </div>
              <.status_badge status={status} />
            </div>

            <div class="p-4 space-y-4">
              <%= if node_singletons != [] do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-seafoam-600 mb-1.5">
                    Singletons
                  </p>
                  <div class="space-y-1">
                    <%= for {module, _} <- node_singletons do %>
                      <div class="px-2 py-1.5 rounded bg-seafoam-900/30 font-mono text-xs text-seafoam-300">
                        {inspect(module)}
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_runners != [] do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-seafoam-600 mb-1.5">
                    Chat Runners
                    <span class="normal-case font-normal text-seafoam-700 ml-1">
                      {length(node_runners)}
                    </span>
                  </p>
                  <div class="space-y-1">
                    <%= for {name, _, _} <- node_runners do %>
                      <div class="px-2 py-1.5 rounded bg-seafoam-900/30 font-mono text-xs text-seafoam-200">
                        {name}
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_liveviews != %{} do %>
                <div>
                  <p class="text-xs font-semibold uppercase tracking-widest text-seafoam-600 mb-1.5">
                    LiveViews
                  </p>
                  <div class="space-y-1">
                    <%= for {view, instances} <- node_liveviews do %>
                      <div class="px-2 py-1.5 rounded bg-seafoam-900/30 flex justify-between items-center gap-2">
                        <span class="font-mono text-xs text-seafoam-200">{short_module(view)}</span>
                        <span class="text-xs text-seafoam-600">×{length(instances)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%= if node_singletons == [] and node_runners == [] and node_liveviews == %{} do %>
                <p class="text-xs text-seafoam-700 italic">No active processes</p>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <% unlocated =
        Enum.filter(@singleton_locations, fn {_, loc} -> is_nil(loc) end) %>
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

      <p class="text-xs text-seafoam-800">
        Nodes, singletons, liveviews &amp; runners all refresh on membership changes.
      </p>
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
        <span class="inline-block px-2 py-0.5 rounded text-xs font-semibold bg-seafoam-900 text-seafoam-300">
          {inspect(other)}
        </span>
    <% end %>
    """
  end
end
