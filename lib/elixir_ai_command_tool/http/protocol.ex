defmodule ElixirAiCommandTool.Http.Protocol do
  @moduledoc """
  JSON encode/decode for HTTP and internal socket communication.

  ## HTTP JSON format

  Request:
    %{"command" => "grep", "args" => ["root", "/etc/passwd"]}

  Response:
    %{"stdout" => "...", "stderr" => "...", "exit_code" => 0}

  ## Internal socket format (shims → daemon)

  Request:  tab-delimited line: "command\\targ1\\targ2\\n"
  Response: :erlang.term_to_binary({stdout, stderr, exit_code})
  """

  @doc "Decode an HTTP JSON request body into {command, args}."
  def decode_http_request(%{"command" => command, "args" => args})
      when is_binary(command) and is_list(args) do
    {:ok, command, args}
  end

  def decode_http_request(_), do: {:error, :invalid_request}

  @doc "Encode execution result as a JSON-serializable map."
  def encode_http_response(stdout, stderr, exit_code) do
    %{"stdout" => stdout, "stderr" => stderr, "exit_code" => exit_code}
  end

  @doc "Parse a tab-delimited socket request line into {command, args}."
  def decode_socket_request(line) when is_binary(line) do
    line = String.trim_trailing(line, "\n")

    case String.split(line, "\t") do
      [command | args] -> {:ok, command, args}
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Encode execution result as Erlang binary term for socket responses."
  def encode_socket_response(stdout, stderr, exit_code) do
    :erlang.term_to_binary({stdout, stderr, exit_code})
  end
end
