defmodule ElixirAiWeb.ChatLive do
  use ElixirAiWeb, :live_view
  import ElixirAiWeb.Spinner
  import ElixirAi.ChatRunner
  alias ElixirAiWeb.Markdown

  @topic "ai_chat"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ElixirAi.PubSub, @topic)
    conversation = get_conversation()

    {:ok,
     socket
     |> assign(user_input: "")
     |> assign(messages: conversation.messages)
     |> assign(streaming_response: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-96 border rounded-lg overflow-hidden">
      <div class="px-4 py-3 font-semibold">
        Live Chat
      </div>
      <div class="flex-1 overflow-y-auto p-4">
        <%= if @messages == [] do %>
          <p class="text-sm text-center mt-4">No messages yet.</p>
        <% end %>
        <%= for msg <- @messages do %>
          <div class={["mb-2 text-sm", if(msg.role == :user, do: "text-right", else: "text-left")]}>
            <%= if msg.role == :assistant do %>
              <span class="inline-block px-3 py-1 rounded-lg border">
                {Markdown.render(msg.reasoning_content)}
              </span>
            <% end %>
            <span class="inline-block px-3 py-1 rounded-lg border">
              {Markdown.render(msg.content)}
            </span>
          </div>
        <% end %>
        <%= if @streaming_response do %>
          <div class="mb-2 text-sm text-left">
            <span class="inline-block px-3 py-1 rounded-lg border">
              {Markdown.render(@streaming_response.reasoning_content)}
            </span>
            <span class="inline-block px-3 py-1 rounded-lg border">
              {Markdown.render(@streaming_response.content)}
            </span>
            <.spinner />
          </div>
        <% end %>
      </div>
      <form class="border-t p-3 flex gap-2" phx-submit="submit" phx-change="update_user_input">
        <input
          type="text"
          name="user_input"
          value={@user_input}
          class="flex-1 border rounded px-3 py-2 text-sm focus:outline-none focus:ring-2"
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
    ElixirAi.ChatRunner.new_user_message(user_input)
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

  def handle_info(:end_ai_response, socket) do
    final_response = %{
      role: :assistant,
      content: socket.assigns.streaming_response.content,
      reasoning_content: socket.assigns.streaming_response.reasoning_content
    }

    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [final_response]))
     |> assign(streaming_response: nil)}
  end
end
