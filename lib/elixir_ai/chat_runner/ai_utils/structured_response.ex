defmodule ElixirAi.AiUtils.StructuredResponse do
  require Logger

  @doc """
  Makes a synchronous AI request that returns parsed structured JSON.

  ## Example

      messages = [%{role: "user", content: "Is this spam?"}]

      provider = %AiProvider{
        completions_url: "https://api.openai.com/v1/chat/completions",
        api_token: "sk-...",
        model_name: "gpt-4o-mini"
      }

      schema = %{
        type: "object",
        properties: %{label: %{type: "string", enum: ["spam", "not_spam"]}},
        required: ["label"],
        additionalProperties: false
      }

      {:ok, %{"label" => "spam"}} =
        StructuredResponse.request(messages, provider, "classification", schema,
          system_prompt: %{role: "system", content: "Classify the message."},
          receive_timeout: 30_000
        )

  """
  def request(messages, provider, schema_name, schema, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    tool_choice = Keyword.get(opts, :tool_choice, "auto")
    system_prompt = Keyword.get(opts, :system_prompt)
    receive_timeout = Keyword.get(opts, :receive_timeout, 120_000)

    full_messages =
      case system_prompt do
        nil -> messages
        prompt -> [prompt | messages]
      end

    response_format = build_response_format(schema_name, schema)
    body = build_body(full_messages, provider.model_name, response_format, tools, tool_choice)
    headers = [{"authorization", "Bearer #{provider.api_token}"}]

    case Req.post(provider.completions_url,
           json: body,
           headers: headers,
           receive_timeout: receive_timeout
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => message} | _]}}} ->
        handle_response_message(message)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        Logger.warning("Structured response request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_response_format(name, schema) do
    %{
      type: "json_schema",
      json_schema: %{
        name: name,
        strict: true,
        schema: schema
      }
    }
  end

  defp build_body(messages, model, response_format, tools, tool_choice) do
    base = %{
      model: model,
      messages: Enum.map(messages, &ElixirAi.ChatUtils.api_message/1),
      response_format: response_format
    }

    if tools == [] do
      base
    else
      Map.merge(base, %{
        tools: Enum.map(tools, & &1.definition),
        tool_choice: tool_choice
      })
    end
  end

  defp handle_response_message(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:json_decode, reason, content}}
    end
  end

  defp handle_response_message(%{"content" => nil} = msg) do
    {:error, {:no_content, msg}}
  end

  defp handle_response_message(msg) do
    {:error, {:unexpected_message, msg}}
  end
end
