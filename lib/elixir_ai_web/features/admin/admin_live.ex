defmodule ElixirAiWeb.AdminLive do
  use ElixirAiWeb, :live_view
  require Logger
  import ElixirAi.PubsubTopics

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        :net_kernel.monitor_nodes(true)
        # Join before monitoring so our own join doesn't trigger a spurious refresh.
        :pg.join(ElixirAi.LiveViewPG, {:liveview, __MODULE__}, self())
        {pg_ref, _} = :pg.monitor_scope(ElixirAi.LiveViewPG)
        {runner_pg_ref, _} = :pg.monitor_scope(ElixirAi.RunnerPG)
        {singleton_pg_ref, _} = :pg.monitor_scope(ElixirAi.SingletonPG)

        Phoenix.PubSub.subscribe(ElixirAi.PubSub, admin_topic())

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

  # Runner joined — fetch initial status once for each new pid.
  def handle_info({ref, :join, {:runner, name}, pids}, %{assigns: %{runner_pg_ref: ref}} = socket)
      when is_reference(ref) do
    new_entries =
      Enum.map(pids, fn pid ->
        status =
          try do
            GenServer.call(pid, {:session, :get_status}, 1_000)
          catch
            _, _ -> :unknown
          end

        {name, node(pid), pid, status}
      end)

    {:noreply,
     update(socket, :chat_runners, fn runners ->
       (runners ++ new_entries) |> Enum.sort_by(&elem(&1, 0))
     end)}
  end

  # Runner left — remove by pid.
  def handle_info(
        {ref, :leave, {:runner, name}, pids},
        %{assigns: %{runner_pg_ref: ref}} = socket
      )
      when is_reference(ref) do
    pid_set = MapSet.new(pids)

    {:noreply,
     update(socket, :chat_runners, fn runners ->
       Enum.reject(runners, fn {n, _, p, _} -> n == name and MapSet.member?(pid_set, p) end)
     end)}
  end

  # Other runner pg events (non-runner groups, etc.) — ignore.
  def handle_info({ref, _change, _group, _pids}, %{assigns: %{runner_pg_ref: ref}} = socket)
      when is_reference(ref) do
    {:noreply, socket}
  end

  # Live status update pushed by the runner via PubSub.
  def handle_info({:runner_status, name, status}, socket) do
    runners =
      Enum.map(socket.assigns.chat_runners, fn
        {^name, node, pid, _} -> {name, node, pid, status}
        entry -> entry
      end)

    {:noreply, assign(socket, chat_runners: runners)}
  end

  defp gather_node_statuses do
    located = ElixirAi.ClusterSingletonLauncher.singleton_locations()

    Enum.map([Node.self() | Node.list()], fn n ->
      status =
        if Enum.any?(located, fn {_, loc} -> loc == n end), do: :running, else: :not_running

      {n, status}
    end)
  end

  defp gather_singleton_locations do
    ElixirAi.ClusterSingletonLauncher.singleton_locations()
  end

  # All ChatRunner entries via :pg membership, keyed by conversation name.
  # Each entry is a {name, node, pid, status} tuple.
  # Status is fetched once on initial load; subsequent updates come via PubSub.
  defp gather_chat_runners do
    :pg.which_groups(ElixirAi.RunnerPG)
    |> Enum.flat_map(fn
      {:runner, name} ->
        :pg.get_members(ElixirAi.RunnerPG, {:runner, name})
        |> Enum.map(fn pid ->
          status =
            try do
              GenServer.call(pid, {:session, :get_status}, 1_000)
            catch
              _, _ -> :unknown
            end

          {name, node(pid), pid, status}
        end)

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
            Enum.filter(@chat_runners, fn {_, rnode, _, _} -> rnode == node end) %>
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
                    <%= for {name, _, _, status} <- node_runners do %>
                      <div class="px-2 py-1.5 rounded bg-seafoam-900/30 flex items-center justify-between gap-2">
                        <span class="font-mono text-xs text-seafoam-200">{name}</span>
                        <.runner_status_badge status={status} />
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

  attr :status, :atom, required: true

  defp runner_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-block px-1.5 py-0.5 rounded text-[10px] font-semibold",
      runner_status_class(@status)
    ]}>
      {runner_status_label(@status)}
    </span>
    """
  end

  defp runner_status_class(:idle), do: "bg-seafoam-900 text-seafoam-400"
  defp runner_status_class(:generating_ai_response), do: "bg-blue-900/60 text-blue-300"
  defp runner_status_class(:awaiting_tools), do: "bg-purple-900/60 text-purple-300"
  defp runner_status_class(:pending_approval), do: "bg-amber-900/60 text-amber-300"
  defp runner_status_class(:initial_startup), do: "bg-seafoam-900/60 text-seafoam-400"
  defp runner_status_class(:stopped), do: "bg-gray-800 text-gray-500"
  defp runner_status_class(:error), do: "bg-red-900/60 text-red-400"
  defp runner_status_class(_), do: "bg-gray-800 text-gray-400"

  defp runner_status_label(:idle), do: "idle"
  defp runner_status_label(:generating_ai_response), do: "thinking"
  defp runner_status_label(:awaiting_tools), do: "tools"
  defp runner_status_label(:pending_approval), do: "approval"
  defp runner_status_label(:initial_startup), do: "starting"
  defp runner_status_label(:stopped), do: "stopped"
  defp runner_status_label(:error), do: "error"
  defp runner_status_label(:unknown), do: "?"
  defp runner_status_label(s), do: inspect(s)

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
