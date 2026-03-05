defmodule ElixirAi.ChatUtils do
  require Logger

  def request_ai_response(server, messages) do
    Task.start(fn ->
      api_url = Application.fetch_env!(:elixir_ai, :ai_endpoint)
      api_key = Application.fetch_env!(:elixir_ai, :ai_token)
      model = Application.fetch_env!(:elixir_ai, :ai_model)

      body = %{
        model: model,
        stream: true,
        messages: messages |> Enum.map(&api_message/1)
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

  def handle_stream_line(_server, "") do
    :ok
  end

  def handle_stream_line(server, "data: [DONE]") do
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
      {:start_new_ai_response, id}
    )
  end

  # last streamed response
  def handle_stream_line(server, %{
        "choices" => [%{"finish_reason" => "stop"}],
        "id" => id
      }) do
    send(
      server,
      {:ai_stream_finish, id}
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
      {:ai_reasoning_chunk, id, reasoning_content}
    )
  end

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
      {:ai_text_chunk, id, reasoning_content}
    )
  end

  def handle_stream_line(_server, unmatched_message) do
    Logger.warning("Received unmatched stream line: #{inspect(unmatched_message)}")
    :ok
  end

  def api_message(%{role: role, content: content}) do
    %{role: Atom.to_string(role), content: content}
  end
end
