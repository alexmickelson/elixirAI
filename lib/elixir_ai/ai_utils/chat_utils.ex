defmodule ElixirAi.ChatUtils do
  require Logger
  import ElixirAi.AiUtils.StreamLineUtils

  def ai_tool(
        name: name,
        description: description,
        function: function,
        parameters: parameters,
        server: server
      ) do
    schema = %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
        # %{
        #   "type" => "object",
        #   "properties" => %{
        #     "name" => %{"type" => "string"},
        #     "value" => %{"type" => "string"}
        #   },
        #   "required" => ["name", "value"]
        # }
      }
    }

    run_function = fn current_message_id, tool_call_id, args ->
      Task.start(fn ->
        result = function.(args)
        send(server, {:tool_response, current_message_id, tool_call_id, result})
      end)
    end

    %{
      name: name,
      definition: schema,
      run_function: run_function
    }
  end

  def request_ai_response(server, messages, tools) do
    Task.start(fn ->
      api_url = Application.fetch_env!(:elixir_ai, :ai_endpoint)
      api_key = Application.fetch_env!(:elixir_ai, :ai_token)
      model = Application.fetch_env!(:elixir_ai, :ai_model)

      if is_nil(api_url) or api_url == "" do
        Logger.warning("AI endpoint is empty or nil")
      end

      if is_nil(api_key) or api_key == "" do
        Logger.warning("AI token is empty or nil")
      end

      if is_nil(model) or model == "" do
        Logger.warning("AI model is empty or nil")
      end

      body = %{
        model: model,
        stream: true,
        messages: messages |> Enum.map(&api_message/1),
        tools: Enum.map(tools, & &1.definition)
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
        {:ok, _response} ->
          :ok

        {:error, reason} ->
          IO.warn("AI request failed: #{inspect(reason)} for #{api_url}")
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
