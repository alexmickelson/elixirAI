defmodule ElixirAi.Mcp.McpServerManager do
  @moduledoc """
  Manages MCP server connections and tool discovery.

  On startup, loads MCP server configs from the database and starts an
  `Anubis.Client` for each enabled server under `ElixirAi.Mcp.McpClientSupervisor`.
  After each client connects (via `Anubis.Client.await_ready/2`), tools are
  discovered asynchronously and cached in an ETS table.

  When the tool set changes, `{:mcp_tools_updated, [{server_name, [tool_map]}]}`
  is broadcast on the `mcp_servers` PubSub topic.

  A full MCP process setup runs on each node; chats talk to their local instance.
  """

  use GenServer
  require Logger
  import ElixirAi.PubsubTopics

  @ets_table :mcp_tools_cache
  @max_connect_attempts 3

  defmodule State do
    @moduledoc false
    defstruct clients: %{},
              monitors: %{},
              attempts: %{}

    @type t :: %__MODULE__{
            clients: %{String.t() => pid()},
            monitors: %{reference() => String.t()},
            attempts: %{String.t() => non_neg_integer()}
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def list_mcp_tools do
    case :ets.whereis(@ets_table) do
      :undefined -> []
      _ -> :ets.tab2list(@ets_table)
    end
  end

  def client_via(name), do: {:via, Registry, {ElixirAi.McpRegistry, name}}

  def server_status(name) do
    case Registry.lookup(ElixirAi.McpRegistry, name) do
      [{_pid, _}] -> :connected
      [] -> :disconnected
    end
  end

  def add_server(name, url, headers \\ %{}) do
    GenServer.call(__MODULE__, {:add_server, name, url, headers}, 15_000)
  end

  def remove_server(name) do
    GenServer.call(__MODULE__, {:remove_server, name}, 10_000)
  end

  def test_connection(_name, url, headers \\ %{}) do
    Task.async(fn ->
      header_map = if is_map(headers), do: headers, else: %{}
      {base_url, mcp_path} = split_mcp_url(url)
      # Use a unique name to avoid registry collisions with the real client
      test_id = "test_#{:erlang.unique_integer([:positive])}"

      child_spec =
        Supervisor.child_spec(
          {Anubis.Client,
           name: {:via, Registry, {ElixirAi.McpRegistry, test_id}},
           transport_name: {:via, Registry, {ElixirAi.McpRegistry, {test_id, :transport}}},
           transport:
             {:streamable_http, base_url: base_url, mcp_path: mcp_path, headers: header_map},
           client_info: %{"name" => "ElixirAI-test", "version" => "1.0.0"},
           capabilities: %{},
           protocol_version: "2025-06-18"},
          restart: :temporary,
          id: {:mcp_test, test_id}
        )

      client_name = {:via, Registry, {ElixirAi.McpRegistry, test_id}}

      case DynamicSupervisor.start_child(ElixirAi.Mcp.McpClientSupervisor, child_spec) do
        {:ok, sup_pid} ->
          result =
            try do
              case Anubis.Client.await_ready(client_name, timeout: 10_000) do
                :ok ->
                  case Anubis.Client.list_tools(client_name, timeout: 10_000) do
                    {:ok, %{result: %{"tools" => tools}}} when is_list(tools) ->
                      {:ok, length(tools)}

                    {:ok, %{result: result}} ->
                      tools = extract_test_tools(result)
                      if tools != [], do: {:ok, length(tools)}, else: {:error, "No tools found"}

                    {:error, reason} ->
                      {:error, inspect(reason)}

                    other ->
                      {:error, "Unexpected: #{inspect(other)}"}
                  end

                _ ->
                  {:error, "Server did not become ready"}
              end
            catch
              :exit, reason -> {:error, "Connection failed: #{inspect(reason)}"}
            end

          DynamicSupervisor.terminate_child(ElixirAi.Mcp.McpClientSupervisor, sup_pid)
          result

        {:error, reason} ->
          {:error, "Failed to start: #{inspect(reason)}"}
      end
    end)
    |> Task.await(30_000)
  catch
    :exit, _ -> {:error, "Connection test timed out"}
  end

  defp extract_test_tools(%{"tools" => tools}) when is_list(tools), do: tools
  defp extract_test_tools(tools) when is_list(tools), do: tools
  defp extract_test_tools(_), do: []

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    else
      :ets.delete_all_objects(@ets_table)
    end

    Phoenix.PubSub.subscribe(ElixirAi.PubSub, mcp_topic())
    send(self(), :load_servers)
    {:ok, %State{}}
  end

  @impl true
  def handle_info(:load_servers, %State{} = state) do
    ElixirAi.McpServer.ensure_mcp_servers_from_file()
    servers = ElixirAi.McpServer.all_enabled()
    Logger.info("McpServerManager loading #{length(servers)} MCP server(s)")

    new_state =
      Enum.reduce(servers, state, fn server, acc ->
        start_client(acc, server)
      end)

    {:noreply, new_state}
  end

  def handle_info({:discover_tools, server_name}, %State{} = state) do
    case Map.get(state.clients, server_name) do
      nil -> {:noreply, state}
      _sup_pid -> {:noreply, discover_tools(state, server_name)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {server_name, monitors} ->
        if reason == :normal do
          Logger.info("MCP client for '#{server_name}' stopped normally")
        else
          Logger.warning("MCP client for '#{server_name}' died: #{inspect(reason)}")
        end

        had_tools = :ets.member(@ets_table, server_name)
        :ets.delete(@ets_table, server_name)
        state = %{state | monitors: monitors, clients: Map.delete(state.clients, server_name)}
        if had_tools, do: broadcast_tools_updated()
        {:noreply, state}
    end
  end

  def handle_info({:mcp_server_added, _}, %State{} = state), do: {:noreply, state}
  def handle_info({:mcp_server_deleted, _}, %State{} = state), do: {:noreply, state}

  def handle_info({:mcp_server_updated, name, %{enabled: true}}, %State{} = state) do
    case ElixirAi.McpServer.find_by_name(name) do
      {:ok, server} ->
        state = %{state | attempts: Map.delete(state.attempts, name)}
        {:noreply, start_client(state, server)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_server_updated, name, %{enabled: false}}, %State{} = state) do
    {:noreply, stop_client(state, name)}
  end

  def handle_info({:mcp_server_updated, _, _}, %State{} = state), do: {:noreply, state}
  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_call({:add_server, name, url, headers}, _from, %State{} = state) do
    server = %ElixirAi.McpServer{name: name, url: url, headers: headers, enabled: true}
    state = %{state | attempts: Map.delete(state.attempts, name)}
    {:reply, :ok, start_client(state, server)}
  end

  def handle_call({:remove_server, name}, _from, %State{} = state) do
    state = stop_client(state, name)
    {:reply, :ok, %{state | attempts: Map.delete(state.attempts, name)}}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp start_client(%State{} = state, %{name: name, url: url, headers: headers}) do
    attempt = Map.get(state.attempts, name, 0) + 1

    if attempt > @max_connect_attempts do
      Logger.error(
        "MCP server '#{name}' failed #{@max_connect_attempts} times, giving up. " <>
          "Remove and re-add the server to retry."
      )

      state
    else
      do_start_client(state, name, url, headers, attempt)
    end
  end

  defp do_start_client(%State{} = state, name, url, headers, attempt) do
    header_map = if is_map(headers), do: headers, else: %{}
    {base_url, mcp_path} = split_mcp_url(url)

    child_spec =
      Supervisor.child_spec(
        {Anubis.Client,
         name: client_via(name),
         transport_name: transport_via(name),
         transport:
           {:streamable_http, base_url: base_url, mcp_path: mcp_path, headers: header_map},
         client_info: %{"name" => "ElixirAI", "version" => "1.0.0"},
         capabilities: %{},
         protocol_version: "2025-06-18"},
        restart: :temporary,
        id: {:mcp_client, name}
      )

    case DynamicSupervisor.start_child(ElixirAi.Mcp.McpClientSupervisor, child_spec) do
      {:ok, pid} ->
        Logger.info("Started MCP client for '#{name}' at #{url} (attempt #{attempt})")
        ref = Process.monitor(pid)
        manager = self()

        Task.start_link(fn ->
          case Anubis.Client.await_ready(client_via(name), timeout: 10_000) do
            :ok ->
              send(manager, {:discover_tools, name})

            _ ->
              Logger.warning("MCP client '#{name}' never became ready, skipping tool discovery")
          end
        end)

        %{
          state
          | clients: Map.put(state.clients, name, pid),
            monitors: Map.put(state.monitors, ref, name),
            attempts: Map.put(state.attempts, name, attempt)
        }

      {:error, reason} ->
        Logger.error("Failed to start MCP client for '#{name}': #{inspect(reason)}")
        %{state | attempts: Map.put(state.attempts, name, attempt)}
    end
  end

  defp stop_client(%State{} = state, name) do
    case Map.get(state.clients, name) do
      nil ->
        state

      sup_pid ->
        DynamicSupervisor.terminate_child(ElixirAi.Mcp.McpClientSupervisor, sup_pid)

        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, state.monitors}, fn {r, n}, {found, acc} ->
            if n == name, do: {r, Map.delete(acc, r)}, else: {found, acc}
          end)

        if ref, do: Process.demonitor(ref, [:flush])
        :ets.delete(@ets_table, name)
        %{state | clients: Map.delete(state.clients, name), monitors: monitors}
    end
  end

  defp remove_client(%State{} = state, name) do
    :ets.delete(@ets_table, name)
    %{state | clients: Map.delete(state.clients, name)}
  end

  defp discover_tools(%State{} = state, server_name) do
    case Anubis.Client.list_tools(client_via(server_name), timeout: 10_000) do
      {:ok, %{result: %{"tools" => tools}}} when is_list(tools) ->
        Logger.info(
          "Discovered #{length(tools)} tool(s) from '#{server_name}': #{inspect(Enum.map(tools, & &1["name"]))}"
        )

        :ets.insert(@ets_table, {server_name, tools})
        broadcast_tools_updated()
        state

      {:ok, %{result: result}} ->
        tools = extract_tools(result)

        if tools != [] do
          Logger.info("Discovered #{length(tools)} tool(s) from MCP server '#{server_name}'")
          :ets.insert(@ets_table, {server_name, tools})
          broadcast_tools_updated()
        else
          Logger.warning(
            "MCP server '#{server_name}' returned unexpected tools/list response: #{inspect(result)}"
          )
        end

        state

      {:error, reason} ->
        Logger.warning(
          "Failed to list tools from MCP server '#{server_name}': #{inspect(reason)}"
        )

        state

      other ->
        Logger.warning("Unexpected tools/list response from '#{server_name}': #{inspect(other)}")
        state
    end
  catch
    :exit, reason ->
      Logger.warning(
        "MCP client for '#{server_name}' is unavailable (tools/list): #{inspect(reason)}"
      )

      remove_client(state, server_name)
  end

  defp extract_tools(%{"tools" => tools}) when is_list(tools), do: tools
  defp extract_tools(tools) when is_list(tools), do: tools
  defp extract_tools(_), do: []

  defp broadcast_tools_updated do
    tools = :ets.tab2list(@ets_table)
    Phoenix.PubSub.broadcast(ElixirAi.PubSub, mcp_topic(), {:mcp_tools_updated, tools})
  end

  # Splits a user-provided URL like "http://host:3000/mcp" into
  # {"http://host:3000", "/mcp"} so Anubis doesn't double-append "/mcp".
  defp split_mcp_url(url) do
    uri = URI.parse(url)
    path = uri.path || "/"

    if path != "/" and path != "" do
      base = URI.to_string(%{uri | path: nil})
      {base, path}
    else
      {url, "/mcp"}
    end
  end

  defp transport_via(name), do: {:via, Registry, {ElixirAi.McpRegistry, {name, :transport}}}
end
