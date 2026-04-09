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
    updated = %{
      socket.assigns.streaming_response
      | reasoning_content:
          socket.assigns.streaming_response.reasoning_content <> reasoning_content
    }

    {:noreply,
     socket
     |> assign(streaming_response: updated)
     |> push_event("reasoning_chunk", %{chunk: reasoning_content})}
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
    updated = %{
      socket.assigns.streaming_response
      | content: socket.assigns.streaming_response.content <> text_content
    }

    {:noreply,
     socket
     |> assign(streaming_response: updated)
     |> push_event("md_chunk", %{chunk: text_content})}
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

  def handle({:end_ai_response, final_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [final_message]))
     |> assign(streaming_response: nil)}
  end

  def handle({:ai_request_error, reason}, socket) do
    error_message =
      case reason do
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
