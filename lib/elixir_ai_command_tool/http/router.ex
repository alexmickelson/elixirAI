defmodule ElixirAiCommandTool.Http.Router do
  @moduledoc """
  HTTP endpoint for receiving command execution requests.

  POST /api/execute
    Body: {"command": "grep", "args": ["root", "/etc/passwd"]}
    Headers: Authorization: Bearer <token> (accepted but not enforced in v1)

  Response: {"stdout": "...", "stderr": "...", "exit_code": 0}
  """

  use Plug.Router

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  alias ElixirAiCommandTool.Runner.CommandExecutor
  alias ElixirAiCommandTool.Http.Protocol

  post "/api/execute" do
    case Protocol.decode_http_request(conn.body_params) do
      {:ok, command, args} ->
        {stdout, stderr, exit_code} = CommandExecutor.execute(command, args)
        response = Protocol.encode_http_response(stdout, stderr, exit_code)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      {:error, :invalid_request} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid request: expected {\"command\": string, \"args\": [string]}"
          })
        )
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
