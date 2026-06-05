defmodule ElixirAi.CommandRunner.SshConnection do
  @moduledoc false
  use GenServer
  require Logger

  @table :elixir_ai_ssh_conn

  @spec start_link(nil | maybe_improper_list() | map()) ::
          :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get do
    case :ets.lookup(@table, :conn_ref) do
      [{:conn_ref, ref}] when is_pid(ref) -> {:ok, ref}
      _ -> GenServer.call(__MODULE__, :connect, 10_000)
    end
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
    {:ok, %{conn_ref: nil}}
  end

  @impl true
  def handle_call(:connect, _from, %{conn_ref: nil} = state) do
    case do_connect() do
      {:ok, ref} ->
        :ets.insert(@table, {:conn_ref, ref})
        {:reply, {:ok, ref}, %{state | conn_ref: ref}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:connect, _from, %{conn_ref: ref} = state) when is_pid(ref) do
    case :ssh.connection_info(ref, [:user]) do
      [{:user, _} | _] ->
        {:reply, {:ok, ref}, state}

      _ ->
        do_close(ref)

        case do_connect() do
          {:ok, new_ref} ->
            :ets.insert(@table, {:conn_ref, new_ref})
            {:reply, {:ok, new_ref}, %{state | conn_ref: new_ref}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | conn_ref: nil}}
        end
    end
  end

  def handle_call(:reconnect, _from, state) do
    if state.conn_ref, do: do_close(state.conn_ref)

    case do_connect() do
      {:ok, ref} ->
        :ets.insert(@table, {:conn_ref, ref})
        {:reply, {:ok, ref}, %{state | conn_ref: ref}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | conn_ref: nil}}
    end
  end

  @impl true
  def terminate(_reason, %{conn_ref: ref}) when is_pid(ref) do
    do_close(ref)
  end

  def terminate(_reason, _state), do: :ok

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
        Logger.error("SSH connection failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_close(ref) do
    :ssh.close(ref)
  rescue
    _ -> :ok
  end
end
