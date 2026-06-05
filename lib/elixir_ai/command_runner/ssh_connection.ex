defmodule ElixirAi.CommandRunner.SshConnection do
  @moduledoc false
  use GenServer
  require Logger

  @table :elixir_ai_ssh_conn
  @reconnect_delay_ms 5_000

  @spec start_link(nil | maybe_improper_list() | map()) ::
          :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get do
    GenServer.call(__MODULE__, :connect, 10_000)
  end

  def reconnect do
    GenServer.call(__MODULE__, :reconnect, 15_000)
  end

  def stop do
    GenServer.stop(__MODULE__)
  end

  @impl true
  def init(_opts) do
    @table = :ets.new(@table, [:named_table, :protected, :set])

    {:ok, %{conn_ref: nil, conn_monitor_ref: nil, reconnect_timer_ref: nil},
     {:continue, :connect_on_startup}}
  end

  @impl true
  def handle_continue(:connect_on_startup, state) do
    {:noreply, ensure_connected(state, :startup)}
  end

  @impl true
  def handle_call(:connect, _from, %{conn_ref: nil} = state) do
    case connect_now(state, :on_demand) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.conn_ref}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:connect, _from, %{conn_ref: ref} = state) when is_pid(ref) do
    if connection_alive?(ref) do
      {:reply, {:ok, ref}, state}
    else
      stale_state = disconnect(state)

      case connect_now(stale_state, :on_demand) do
        {:ok, new_state} ->
          {:reply, {:ok, new_state.conn_ref}, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    end
  end

  def handle_call(:reconnect, _from, state) do
    disconnected_state = disconnect(state)

    case connect_now(disconnected_state, :manual_reconnect) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.conn_ref}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:retry_connect, state) do
    {:noreply, ensure_connected(%{state | reconnect_timer_ref: nil}, :retry)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_monitor_ref: ref} = state) do
    Logger.error("SSH connection process exited: #{inspect(reason)}")
    disconnected_state = disconnect(%{state | conn_monitor_ref: nil})
    {:noreply, schedule_reconnect(disconnected_state, :connection_down)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn_ref: ref}) when is_pid(ref) do
    do_close(ref)
  end

  def terminate(_reason, _state), do: :ok

  defp ensure_connected(%{conn_ref: ref} = state, _source) when is_pid(ref) do
    if connection_alive?(ref) do
      state
    else
      stale_state = disconnect(state)

      case connect_now(stale_state, :retry) do
        {:ok, new_state} -> new_state
        {:error, _reason, new_state} -> schedule_reconnect(new_state, :retry_failed)
      end
    end
  end

  defp ensure_connected(state, source) do
    case connect_now(state, source) do
      {:ok, new_state} -> new_state
      {:error, _reason, new_state} -> schedule_reconnect(new_state, :initial_failure)
    end
  end

  defp connect_now(state, source) do
    case do_connect() do
      {:ok, ref} ->
        monitor_ref = Process.monitor(ref)
        :ets.insert(@table, {:conn_ref, ref})

        {:ok, %{cancel_reconnect_timer(state) | conn_ref: ref, conn_monitor_ref: monitor_ref}}

      {:error, reason} ->
        log_connect_failure(source, reason)
        :ets.delete(@table, :conn_ref)
        {:error, reason, %{state | conn_ref: nil, conn_monitor_ref: nil}}
    end
  end

  defp disconnect(state) do
    if state.conn_monitor_ref, do: Process.demonitor(state.conn_monitor_ref, [:flush])
    if state.conn_ref, do: do_close(state.conn_ref)

    :ets.delete(@table, :conn_ref)
    %{state | conn_ref: nil, conn_monitor_ref: nil}
  end

  defp schedule_reconnect(%{reconnect_timer_ref: nil} = state, reason) do
    Logger.warning(
      "Scheduling SSH reconnect attempt in #{@reconnect_delay_ms}ms (#{inspect(reason)})"
    )

    timer_ref = Process.send_after(self(), :retry_connect, @reconnect_delay_ms)
    %{state | reconnect_timer_ref: timer_ref}
  end

  defp schedule_reconnect(state, _reason), do: state

  defp cancel_reconnect_timer(%{reconnect_timer_ref: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | reconnect_timer_ref: nil}
  end

  defp log_connect_failure(:startup, reason) do
    Logger.error("Initial SSH connection attempt failed: #{inspect(reason)}")
  end

  defp log_connect_failure(:retry, reason) do
    Logger.error("SSH reconnect attempt failed: #{inspect(reason)}")
  end

  defp log_connect_failure(:manual_reconnect, reason) do
    Logger.error("Manual SSH reconnect attempt failed: #{inspect(reason)}")
  end

  defp log_connect_failure(:on_demand, reason) do
    Logger.error("On-demand SSH connection attempt failed: #{inspect(reason)}")
  end

  defp log_connect_failure(_source, reason) do
    Logger.error("SSH connection attempt failed: #{inspect(reason)}")
  end

  defp do_connect do
    host = System.get_env("SANDBOX_SSH_HOST", "llm_sandbox")
    port = System.get_env("SANDBOX_SSH_PORT", "22") |> String.to_integer()
    user = System.get_env("SANDBOX_SSH_USER", "sandbox")
    key_dir = System.get_env("SANDBOX_SSH_KEY_DIR", "/ssh_keys")

    opts = [
      user: String.to_charlist(user),
      user_dir: String.to_charlist(key_dir),
      silently_accept_hosts: true,
      connect_timeout: 10_000,
      user_interaction: false
    ]

    host_charlist = String.to_charlist(host)

    Logger.info("Connecting to #{user}@#{host}:#{port} via :ssh")

    case :ssh.connect(host_charlist, port, opts, 15_000) do
      {:ok, conn_ref} ->
        Logger.info("SSH connection established: #{inspect(conn_ref)}")
        {:ok, conn_ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_close(ref) do
    :ssh.close(ref)
  rescue
    _ -> :ok
  end

  defp connection_alive?(ref) when is_pid(ref) do
    Process.alive?(ref) and match?([{:user, _} | _], :ssh.connection_info(ref, [:user]))
  rescue
    _ -> false
  end
end
