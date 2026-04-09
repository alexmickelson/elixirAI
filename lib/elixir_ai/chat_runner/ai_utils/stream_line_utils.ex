defmodule ElixirAi.AiUtils.StreamLineUtils do
  require Logger

  def handle_stream_line(_server, "") do
    :ok
  end

  def handle_stream_line(_server, "data: [DONE]") do
    # send(server, :ai_stream_done)
    :ok
  end

  def handle_stream_line(server, "data: " <> json) do
    case Jason.decode(json) do
      {:ok, body} ->
        # Logger.debug("Received AI chunk: #{inspect(body)}")
        handle_stream_line(server, body)

      other ->
        Logger.error("Failed to decode AI response chunk: #{inspect(other)}")
        :ok
    end
  end

  # first streamed response
  def handle_stream_line(server, %{
        "choices" => [%{"delta" => %{"content" => nil, "role" => "assistant"}}],
        "id" => id
      }) do
    send(
      server,
      {:stream, {:start_new_ai_response, id}}
    )
  end

  # last streamed response — content finished, wait for the usage chunk
  def handle_stream_line(
        server,
        %{
          "choices" => [%{"finish_reason" => "stop"}],
          "id" => id
        } = _msg
      ) do
    send(
      server,
      {:stream, {:ai_text_stream_finish, id}}
    )
  end

  # usage chunk — emitted after finish_reason: "stop" when stream_options.include_usage is true
  def handle_stream_line(server, %{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => prompt_tokens,
          "completion_tokens" => completion_tokens
        }
      }) do
    send(
      server,
      {:stream, {:ai_usage, prompt_tokens, completion_tokens}}
    )
  end

  # streamed in reasoning
  def handle_stream_line(server, %{
        "choices" => [
          %{
            "delta" => %{"reasoning_content" => reasoning_content},
            "finish_reason" => nil
          }
        ],
        "id" => id
      }) do
    send(
      server,
      {:stream, {:ai_reasoning_chunk, id, reasoning_content}}
    )
  end

  # streamed in text
  def handle_stream_line(server, %{
        "choices" => [
          %{
            "delta" => %{"content" => reasoning_content},
            "finish_reason" => nil
          }
        ],
        "id" => id
      }) do
    send(
      server,
      {:stream, {:ai_text_chunk, id, reasoning_content}}
    )
  end

  # start and middle tool call
  def handle_stream_line(server, %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => tool_calls
            },
            "finish_reason" => nil
          }
        ],
        "id" => id
      })
      when is_list(tool_calls) do
    Enum.each(tool_calls, fn
      %{
        "id" => tool_call_id,
        "index" => tool_index,
        "type" => "function",
        "function" => %{"name" => tool_name, "arguments" => tool_args_start}
      } ->
        # Logger.info("Received tool call start for tool #{tool_name}")

        send(
          server,
          {:stream,
           {:ai_tool_call_start, id, {tool_name, tool_args_start, tool_index, tool_call_id}}}
        )

      %{"index" => tool_index, "function" => %{"arguments" => tool_args_diff}} ->
        # Logger.info("Received tool call middle for index #{tool_index}")
        send(server, {:stream, {:ai_tool_call_middle, id, {tool_args_diff, tool_index}}})

      other ->
        Logger.warning("Unmatched tool call item: #{inspect(other)}")
    end)
  end

  # end tool call
  def handle_stream_line(
        server,
        %{
          "choices" => [%{"finish_reason" => "tool_calls"}],
          "id" => id
        }
      ) do
    # Logger.info("Received tool_calls_finished with message: #{inspect(message)}")
    send(server, {:stream, {:ai_tool_call_end, id}})
  end

  def handle_stream_line(server, %{"error" => error_info}) do
    Logger.error("Received error from AI stream: #{inspect(error_info)}")
    send(server, {:stream, {:ai_request_error, error_info}})
  end

  def handle_stream_line(server, "proxy error" <> _ = error) when is_binary(error) do
    Logger.error("Proxy error in AI stream: #{error}")
    send(server, {:stream, {:ai_request_error, error}})
  end

  def handle_stream_line(server, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, body} ->
        handle_stream_line(server, body)

      _ ->
        Logger.warning("Received unmatched stream line: #{inspect(json)}")
        :ok
    end
  end

  def handle_stream_line(_server, unmatched_message) do
    Logger.warning("Received unmatched stream line: #{inspect(unmatched_message)}")
    :ok
  end
end
