defmodule ElixirAi.ChatUtils do
  require Logger
  import ElixirAi.AiUtils.StreamLineUtils

  def request_ai_response(server, messages, tools) do
    Task.start(fn ->
      api_url = Application.fetch_env!(:elixir_ai, :ai_endpoint)
      api_key = Application.fetch_env!(:elixir_ai, :ai_token)
      model = Application.fetch_env!(:elixir_ai, :ai_model)

      tool_definition = tools |> Enum.map(fn {_name, definition} -> definition end)

      body = %{
        model: model,
        stream: true,
        messages: messages |> Enum.map(&api_message/1),
        tools: tool_definition
      }

      headers = [{"authorization", "Bearer #{api_key}"}]

      Logger.info("sending AI request with body: #{inspect(body)}")
      case Req.post(api_url,
             json: body,
             headers: headers,
             into: fn {:data, data}, acc ->
               data
               |> String.split("\n")
               |> Enum.each(&handle_stream_line(server, &1))

               {:cont, acc}
             end
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          IO.warn("AI request failed: #{inspect(reason)}")
      end
    end)
  end

  def api_message(%{role: :assistant, tool_calls: [_ | _] = tool_calls} = msg) do
    %{
      role: "assistant",
      content: Map.get(msg, :content, ""),
      tool_calls:
        Enum.map(tool_calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{
              name: call.name,
              arguments: call.arguments
            }
          }
        end)
    }
  end

  def api_message(%{role: :tool, tool_call_id: tool_call_id, content: content}) do
    %{role: "tool", tool_call_id: tool_call_id, content: content}
  end

  def api_message(%{role: role, content: content}) do
    %{role: Atom.to_string(role), content: content}
  end
end
