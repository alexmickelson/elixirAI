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

  def api_message(%{role: role, content: content}) do
    %{role: Atom.to_string(role), content: content}
  end
end
