defmodule ElixirAi.Mcp.McpServerManager do
  @moduledoc """
  Manages MCP server connections and tool discovery.

  On startup, loads MCP server configs from the database and starts an
  `Anubis.Client` for each enabled server under `ElixirAi.Mcp.McpClientSupervisor`.
  After each client connects, it calls `tools/list` to discover available tools
  and caches the results.

  Provides:
  - `list_mcp_tools/0` — all discovered tools grouped by server
  - `all_mcp_tool_names/0` — flat list of namespaced tool names
  - `call_mcp_tool/3` — route a tool call to the correct MCP server client
  """

  use GenServer
  require Logger
  import ElixirAi.PubsubTopics

  @tool_discovery_delay 2_000
  @max_connect_attempts 3

  defmodule ServerConfig do
    @moduledoc false
    @enforce_keys [:url]
    defstruct [:url, headers: %{}]

    @type t :: %__MODULE__{url: String.t(), headers: map()}
  end

  defmodule State do
    @moduledoc false
    defstruct clients: %{},
              tools: %{},
              configs: %{},
              monitors: %{},
              attempts: %{}

    @type t :: %__MODULE__{
            clients: %{String.t() => pid()},
            tools: %{String.t() => [map()]},
            configs: %{String.t() => ServerConfig.t()},
            monitors: %{reference() => String.t()},
            attempts: %{String.t() => non_neg_integer()}
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns `[{server_name, [tool_map, ...]}]`."
  def list_mcp_tools do
    GenServer.call(__MODULE__, :list_mcp_tools, 10_000)
  catch
    :exit, _ -> []
  end

  @doc "Flat list of all namespaced tool names (e.g. `mcp:server:tool`)."
  def all_mcp_tool_names do
    case list_mcp_tools() do
      tools when is_list(tools) ->
        Enum.flat_map(tools, fn {server_name, server_tools} ->
          Enum.map(server_tools, fn tool -> "mcp:#{server_name}:#{tool["name"]}" end)
        end)

      _ ->
        []
    end
  end

  @doc "Call a tool on the named MCP server. Returns `{:ok, text}` or `{:error, reason}`."
  def call_mcp_tool(server_name, tool_name, arguments) do
    GenServer.call(__MODULE__, {:call_tool, server_name, tool_name, arguments}, 60_000)
  catch
    :exit, reason -> {:error, "MCP call failed: #{inspect(reason)}"}
  end

  @doc "Add and start a new MCP server at runtime."
  def add_server(name, url, headers \\ %{}) do
    GenServer.call(__MODULE__, {:add_server, name, url, headers}, 15_000)
  end

  @doc "Remove an MCP server and stop its client."
  def remove_server(name) do
    GenServer.call(__MODULE__, {:remove_server, name}, 10_000)
  end

  @doc "Returns `:connected | :disconnected` for a given server."
  def server_status(name) do
    GenServer.call(__MODULE__, {:server_status, name}, 5_000)
  catch
    :exit, _ -> :disconnected
  end

  @doc "Test connectivity — tries to connect and list tools. Returns `{:ok, tool_count}` or `{:error, reason}`."
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

      case DynamicSupervisor.start_child(ElixirAi.Mcp.McpClientSupervisor, child_spec) do
        {:ok, pid} ->
          result =
            try do
              Process.sleep(1_500)

              case Anubis.Client.list_tools(pid, timeout: 10_000) do
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
            catch
              :exit, reason -> {:error, "Connection failed: #{inspect(reason)}"}
            end

          DynamicSupervisor.terminate_child(ElixirAi.Mcp.McpClientSupervisor, pid)
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
    Phoenix.PubSub.subscribe(ElixirAi.PubSub, mcp_topic())
    send(self(), :load_servers)
    {:ok, %State{}}
  end

  @impl true
  def handle_info(:load_servers, %State{} = state) do
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
      nil ->
        {:noreply, state}

      client_pid ->
        if Process.alive?(client_pid) do
          {:noreply, discover_tools(state, server_name, client_pid)}
        else
          Logger.warning("MCP client for '#{server_name}' is no longer alive, skipping discovery")
          {:noreply, remove_client(state, server_name)}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {server_name, monitors} ->
        state = %{state | monitors: monitors}

        if reason == :normal do
          Logger.info("MCP client for '#{server_name}' stopped normally")
        else
          Logger.warning("MCP client for '#{server_name}' died: #{inspect(reason)}")
        end

        had_tools = Map.has_key?(state.tools, server_name)

        state = %{
          state
          | clients: Map.delete(state.clients, server_name),
            tools: Map.delete(state.tools, server_name)
        }

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
  def handle_call(:list_mcp_tools, _from, %State{tools: tools} = state) do
    {:reply, Enum.to_list(tools), state}
  end

  def handle_call({:call_tool, server_name, tool_name, arguments}, _from, %State{} = state) do
    case Map.get(state.clients, server_name) do
      nil ->
        {:reply, {:error, "MCP server '#{server_name}' not connected"}, state}

      client_pid ->
        if Process.alive?(client_pid) do
          {:reply, do_call_tool(client_pid, tool_name, arguments), state}
        else
          {:reply, {:error, "MCP server '#{server_name}' is unavailable"},
           remove_client(state, server_name)}
        end
    end
  end

  def handle_call({:add_server, name, url, headers}, _from, %State{} = state) do
    server = %ElixirAi.McpServer{name: name, url: url, headers: headers, enabled: true}
    state = %{state | attempts: Map.delete(state.attempts, name)}
    {:reply, :ok, start_client(state, server)}
  end

  def handle_call({:remove_server, name}, _from, %State{} = state) do
    state = stop_client(state, name)
    {:reply, :ok, %{state | attempts: Map.delete(state.attempts, name)}}
  end

  def handle_call({:server_status, name}, _from, %State{} = state) do
    status =
      case Map.get(state.clients, name) do
        nil -> :disconnected
        pid -> if Process.alive?(pid), do: :connected, else: :disconnected
      end

    {:reply, status, state}
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
        Process.send_after(self(), {:discover_tools, name}, @tool_discovery_delay)

        %{
          state
          | clients: Map.put(state.clients, name, pid),
            configs: Map.put(state.configs, name, %ServerConfig{url: url, headers: header_map}),
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

      _pid ->
        case Registry.lookup(ElixirAi.McpRegistry, name) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(ElixirAi.Mcp.McpClientSupervisor, pid)

          _ ->
            :ok
        end

        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, state.monitors}, fn {r, n}, {found, acc} ->
            if n == name, do: {r, Map.delete(acc, r)}, else: {found, acc}
          end)

        if ref, do: Process.demonitor(ref, [:flush])

        %{
          state
          | clients: Map.delete(state.clients, name),
            tools: Map.delete(state.tools, name),
            configs: Map.delete(state.configs, name),
            monitors: monitors
        }
    end
  end

  defp remove_client(%State{} = state, name) do
    %{
      state
      | clients: Map.delete(state.clients, name),
        tools: Map.delete(state.tools, name)
    }
  end

  defp discover_tools(%State{} = state, server_name, client_pid) do
    case Anubis.Client.list_tools(client_pid, timeout: 10_000) do
      {:ok, %{result: %{"tools" => tools}}} when is_list(tools) ->
        Logger.info(
          "Discovered #{length(tools)} tool(s) from MCP server '#{server_name}': #{inspect(Enum.map(tools, & &1["name"]))}"
        )

        broadcast_tools_updated()
        %{state | tools: Map.put(state.tools, server_name, tools)}

      {:ok, %{result: result}} ->
        tools = extract_tools(result)

        if tools != [] do
          Logger.info("Discovered #{length(tools)} tool(s) from MCP server '#{server_name}'")
          broadcast_tools_updated()
          %{state | tools: Map.put(state.tools, server_name, tools)}
        else
          Logger.warning(
            "MCP server '#{server_name}' returned unexpected tools/list response: #{inspect(result)}"
          )

          state
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to list tools from MCP server '#{server_name}': #{inspect(reason)}"
        )

        state

      other ->
        Logger.warning(
          "Unexpected response from MCP server '#{server_name}' tools/list: #{inspect(other)}"
        )

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

  defp do_call_tool(client_pid, tool_name, arguments) do
    case Anubis.Client.call_tool(client_pid, tool_name, arguments, timeout: 60_000) do
      {:ok, %{result: %{"content" => content}}} when is_list(content) ->
        text =
          content
          |> Enum.map(fn
            %{"type" => "text", "text" => t} -> t
            other -> inspect(other)
          end)
          |> Enum.join("\n")

        {:ok, text}

      {:ok, %{result: result}} ->
        {:ok, inspect(result)}

      {:error, reason} ->
        {:error, "MCP tool call failed: #{inspect(reason)}"}

      other ->
        {:error, "Unexpected MCP response: #{inspect(other)}"}
    end
  catch
    :exit, reason ->
      {:error, "MCP server unavailable: #{inspect(reason)}"}
  end

  defp broadcast_tools_updated do
    Phoenix.PubSub.broadcast(ElixirAi.PubSub, mcp_topic(), :mcp_tools_updated)
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

  defp client_via(name), do: {:via, Registry, {ElixirAi.McpRegistry, name}}
  defp transport_via(name), do: {:via, Registry, {ElixirAi.McpRegistry, {name, :transport}}}
end
