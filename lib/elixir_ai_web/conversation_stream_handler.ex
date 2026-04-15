defmodule ElixirAiWeb.ConversationStreamHandler do
  @moduledoc """
  Shared handler for `{:conversation_stream_message, inner}` PubSub messages
  broadcast by the ChatRunner cluster.  Both `ChatLive` and `VoiceLive` delegate
  their single `handle_info({:conversation_stream_message, msg}, socket)` clause
  here so the streaming logic lives in one place.
  """

  import Phoenix.Component, only: [assign: 2, update: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def handle({:user_chat_message, message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [message]))
     |> push_event("scroll_to_bottom", %{})}
  end

  def handle(
        {:start_ai_response_stream,
         %{id: _id, reasoning_content: "", content: ""} = starting_response},
        socket
      ) do
    {:noreply, assign(socket, streaming_response: starting_response)}
  end

  # Chunk arrived before :start_ai_response_stream — fetch snapshot from runner.
  def handle(
        {:reasoning_chunk_content, reasoning_content},
        %{assigns: %{streaming_response: nil}} = socket
      ) do
    base = get_snapshot(socket) |> Map.update!(:reasoning_content, &(&1 <> reasoning_content))
    {:noreply, assign(socket, streaming_response: base)}
  end

  def handle({:reasoning_chunk_content, reasoning_content}, socket) do
    # Only update the assign on the first reasoning chunk — this reveals the
    # toggle button via a LiveView re-render. All subsequent chunks are rendered
    # client-side via push_event to avoid per-token re-render diffs.
    socket =
      if socket.assigns.streaming_response.reasoning_content == "" do
        assign(socket,
          streaming_response: %{
            socket.assigns.streaming_response
            | reasoning_content: reasoning_content
          }
        )
      else
        socket
      end

    {:noreply, push_event(socket, "reasoning_chunk", %{chunk: reasoning_content})}
  end

  # Chunk arrived before :start_ai_response_stream — fetch snapshot from runner.
  def handle(
        {:text_chunk_content, text_content},
        %{assigns: %{streaming_response: nil}} = socket
      ) do
    base = get_snapshot(socket) |> Map.update!(:content, &(&1 <> text_content))
    {:noreply, assign(socket, streaming_response: base)}
  end

  def handle({:text_chunk_content, text_content}, socket) do
    # Content is rendered entirely client-side via the MarkdownStream push_event.
    # Updating the assign on every token triggers a LiveView re-render diff cycle
    # which calls updated() on the ScrollBottom hook — causing the scroll-to-bottom
    # race against the user's scroll position.
    {:noreply, push_event(socket, "md_chunk", %{chunk: text_content})}
  end

  def handle({:streaming_tool_call_start, tool_call}, socket) do
    streaming_response =
      socket.assigns.streaming_response || get_snapshot(socket)

    updated = %{streaming_response | tool_calls: streaming_response.tool_calls ++ [tool_call]}
    {:noreply, assign(socket, streaming_response: updated)}
  end

  def handle({:streaming_tool_args_chunk, tool_index, args_diff}, socket) do
    case socket.assigns.streaming_response do
      nil ->
        {:noreply, socket}

      resp ->
        updated_calls =
          Enum.map(resp.tool_calls, fn
            %{index: ^tool_index, arguments: existing} = tc ->
              %{tc | arguments: existing <> args_diff}

            other ->
              other
          end)

        {:noreply, assign(socket, streaming_response: %{resp | tool_calls: updated_calls})}
    end
  end

  def handle(:tool_calls_finished, socket) do
    {:noreply, assign(socket, streaming_response: nil)}
  end

  def handle({:tool_request_message, tool_request_message}, socket) do
    # Tool calls are finalized in @messages — clear streaming_response so the
    # streaming bubble doesn't render below the incoming tool results.
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [tool_request_message]))
     |> assign(streaming_response: nil)}
  end

  def handle({:one_tool_finished, tool_response}, socket) do
    {:noreply, update(socket, :messages, &(&1 ++ [tool_response]))}
  end

  def handle({:tool_approval_updated, tool_call_id, decision, justification}, socket) do
    updated_messages =
      Enum.map(socket.assigns.messages, fn msg ->
        case msg do
          %{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) ->
            updated_calls =
              Enum.map(tool_calls, fn tc ->
                if tc.id == tool_call_id,
                  do:
                    Map.merge(tc, %{
                      approval_decision: decision,
                      approval_justification: justification
                    }),
                  else: tc
              end)

            %{msg | tool_calls: updated_calls}

          other ->
            other
        end
      end)

    {:noreply, assign(socket, messages: updated_messages)}
  end

  def handle({:end_ai_response, final_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [final_message]))
     |> assign(streaming_response: nil)}
  end

  def handle({:inline_error_message, error_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [error_message]))
     |> push_event("scroll_to_bottom", %{})}
  end

  def handle({:ai_request_error, reason}, socket) do
    error_message =
      case reason do
        %{"message" => msg} ->
          msg

        "proxy error" <> _ ->
          "Could not connect to AI provider. Please check your proxy and provider settings."

        %{__struct__: mod, reason: r} ->
          "#{inspect(mod)}: #{inspect(r)}"

        msg when is_binary(msg) ->
          msg

        _ ->
          inspect(reason)
      end

    {:noreply, assign(socket, ai_error: error_message, streaming_response: nil)}
  end

  def handle({:db_error, reason}, socket) do
    {:noreply, assign(socket, db_error: reason)}
  end

  def handle(:recovery_restart, socket) do
    {:noreply, assign(socket, streaming_response: nil, ai_error: nil)}
  end

  def handle(:stopped, socket) do
    {:noreply, assign(socket, streaming_response: nil)}
  end

  def handle({:stopped, partial_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [partial_message]))
     |> assign(streaming_response: nil)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_snapshot(%{assigns: %{runner_pid: pid}}) when is_pid(pid) do
    case GenServer.call(pid, {:conversation, :get_streaming_response}) do
      nil -> %{id: nil, content: "", reasoning_content: "", tool_calls: []}
      snapshot -> snapshot
    end
  end

  defp get_snapshot(_socket) do
    %{id: nil, content: "", reasoning_content: "", tool_calls: []}
  end
end
