defmodule ElixirAiWeb.ChatLive do
  use ElixirAiWeb, :live_view
  require Logger
  import ElixirAiWeb.Spinner
  import ElixirAiWeb.ChatMessage
  alias ElixirAi.ChatRunner

  @topic "ai_chat"

  def valid_background_colors do
    [
      "bg-cyan-950/30",
      "bg-red-950/30",
      "bg-green-950/30",
      "bg-blue-950/30",
      "bg-yellow-950/30",
      "bg-purple-950/30",
      "bg-pink-950/30"
    ]
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ElixirAi.PubSub, @topic)
    conversation = ChatRunner.get_conversation()

    {:ok,
     socket
     |> assign(user_input: "")
     |> assign(messages: conversation.messages)
     |> assign(streaming_response: nil)
     |> assign(background_color: "bg-cyan-950/30")}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full  rounded-lg">
      <div class="px-4 py-3 font-semibold ">
        Live Chat
      </div>
      <div
        id="chat-messages"
        phx-hook="ScrollBottom"
        class={"flex-1 overflow-y-auto p-4 rounded-lg #{@background_color}"}
      >
        <%= if @messages == [] do %>
          <p class="text-sm text-center mt-4">No messages yet.</p>
        <% end %>
        <%= for msg <- @messages do %>
          <%= cond do %>
            <% msg.role == :user -> %>
              <.user_message content={msg.content} />
            <% msg.role == :tool -> %>
              <.tool_result_message content={msg.content} tool_call_id={msg.tool_call_id} />
            <% true -> %>
              <.assistant_message
                content={msg.content}
                reasoning_content={msg.reasoning_content}
                tool_calls={Map.get(msg, :tool_calls, [])}
              />
          <% end %>
        <% end %>
        <%= if @streaming_response do %>
          <.streaming_assistant_message
            content={@streaming_response.content}
            reasoning_content={@streaming_response.reasoning_content}
            tool_calls={@streaming_response.tool_calls}
          />
          <.spinner />
        <% end %>
      </div>
      <form class="p-3 flex gap-2" phx-submit="submit" phx-change="update_user_input">
        <input
          type="text"
          name="user_input"
          value={@user_input}
          class="flex-1 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2"
        />
        <button type="submit" class="px-4 py-2 rounded text-sm border">
          Send
        </button>
      </form>
    </div>
    """
  end

  def handle_event("update_user_input", %{"user_input" => user_input}, socket) do
    {:noreply, assign(socket, user_input: user_input)}
  end

  def handle_event("submit", %{"user_input" => user_input}, socket) when user_input != "" do
    ChatRunner.new_user_message(user_input)
    {:noreply, assign(socket, user_input: "")}
  end

  def handle_info({:user_chat_message, message}, socket) do
    {:noreply, update(socket, :messages, &(&1 ++ [message]))}
  end

  def handle_info(
        {:start_ai_response_stream,
         %{id: _id, reasoning_content: "", content: ""} = starting_response},
        socket
      ) do
    {:noreply, assign(socket, streaming_response: starting_response)}
  end

  def handle_info({:reasoning_chunk_content, reasoning_content}, socket) do
    updated_response = %{
      socket.assigns.streaming_response
      | reasoning_content:
          socket.assigns.streaming_response.reasoning_content <> reasoning_content
    }

    {:noreply, assign(socket, streaming_response: updated_response)}
  end

  def handle_info({:text_chunk_content, text_content}, socket) do
    updated_response = %{
      socket.assigns.streaming_response
      | content: socket.assigns.streaming_response.content <> text_content
    }

    {:noreply, assign(socket, streaming_response: updated_response)}
  end

  def handle_info(:tool_calls_finished, socket) do
    Logger.info("Received tool_calls_finished")

    {:noreply,
     socket
     |> assign(streaming_response: nil)}
  end

  def handle_info({:tool_request_message, tool_request_message}, socket) do
    Logger.info("tool request message: #{inspect(tool_request_message)}")

    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [tool_request_message]))}
  end

  def handle_info({:one_tool_finished, tool_response}, socket) do
    Logger.info("Received one_tool_finished with #{inspect(tool_response)}")

    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [tool_response]))}
  end

  def handle_info({:end_ai_response, final_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [final_message]))
     |> assign(streaming_response: nil)}
  end

  def handle_info({:set_background_color, color}, socket) do
    Logger.info("setting background color to #{color}")
    {:noreply, assign(socket, background_color: color)}
  end
end
