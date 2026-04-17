defmodule ElixirAi.Mcp.McpToolAdapter do
  @moduledoc """
  Converts MCP tool schemas into the tool format used by the chat system.

  MCP tools discovered via `Anubis.Client.list_tools/1` are translated into
  the `%{name, definition, run_function}` shape that `StreamHandler` dispatches.

  Tool names are namespaced as `mcp:<server>:<tool>` to avoid collisions with
  built-in server/liveview tools.
  """

  require Logger

  def build_mcp_tools(chat_runner_pid, mcp_server_name, mcp_tools) do
    Enum.map(mcp_tools, fn mcp_tool ->
      tool_name = "mcp:#{mcp_server_name}:#{mcp_tool["name"]}"

      definition = %{
        "type" => "function",
        "function" => %{
          "name" => tool_name,
          "description" => mcp_tool["description"] || mcp_tool["name"],
          "parameters" => mcp_tool["inputSchema"] || %{"type" => "object", "properties" => %{}}
        }
      }

      run_function = fn current_message_id, tool_call_id, args ->
        Task.start_link(fn ->
          try do
            result =
              ElixirAi.Mcp.McpServerManager.call_mcp_tool(
                mcp_server_name,
                mcp_tool["name"],
                args
              )

            send(
              chat_runner_pid,
              {:stream, {:tool_response, current_message_id, tool_call_id, result}}
            )
          rescue
            e ->
              reason = Exception.format(:error, e, __STACKTRACE__)
              Logger.error("MCP tool task crashed for #{tool_name}: #{reason}")

              send(
                chat_runner_pid,
                {:stream, {:tool_response, current_message_id, tool_call_id, {:error, reason}}}
              )
          end
        end)
      end

      %{name: tool_name, definition: definition, run_function: run_function}
    end)
  end

  def build_allowed_mcp_tools(chat_runner_pid, allowed_names) do
    case ElixirAi.Mcp.McpServerManager.list_mcp_tools() do
      tools when is_list(tools) ->
        Enum.flat_map(tools, fn {server_name, server_tools} ->
          build_mcp_tools(chat_runner_pid, server_name, server_tools)
        end)
        |> Enum.filter(&(&1.name in allowed_names))

      _ ->
        []
    end
  end

  def all_mcp_tool_names do
    case ElixirAi.Mcp.McpServerManager.list_mcp_tools() do
      tools when is_list(tools) ->
        Enum.flat_map(tools, fn {server_name, server_tools} ->
          Enum.map(server_tools, fn tool -> "mcp:#{server_name}:#{tool["name"]}" end)
        end)

      _ ->
        []
    end
  end
end
