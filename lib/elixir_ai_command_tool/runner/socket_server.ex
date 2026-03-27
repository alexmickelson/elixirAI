defmodule ElixirAiCommandTool.Runner.SocketServer do
  @moduledoc """
  Internal Unix domain socket server for shim communication.

  Listens on `/tmp/tool_runner.sock` and spawns a handler process
  for each incoming connection. Shims inside the container send
  tab-delimited requests and receive Erlang binary term responses.
  """

  use GenServer
  require Logger

  @socket_path "/tmp/tool_runner.sock"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Clean up stale socket file
    File.rm(@socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true,
           ifaddr: {:local, @socket_path}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("SocketServer listening on #{@socket_path}")
        # Start the accept loop in a separate process
        spawn_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{listen_socket: listen_socket}}

      {:error, reason} ->
        Logger.error("SocketServer failed to start: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        spawn(fn -> handle_client(client_socket) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("SocketServer accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handle_client(socket) do
    alias ElixirAiCommandTool.Runner.CommandExecutor
    alias ElixirAiCommandTool.Http.Protocol

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        case Protocol.decode_socket_request(data) do
          {:ok, command, args} ->
            {stdout, stderr, exit_code} = CommandExecutor.execute(command, args)
            response = Protocol.encode_socket_response(stdout, stderr, exit_code)
            :gen_tcp.send(socket, response)

          {:error, _} ->
            response = Protocol.encode_socket_response("", "invalid request", 1)
            :gen_tcp.send(socket, response)
        end

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end
end
