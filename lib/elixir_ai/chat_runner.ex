defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  import ElixirAi.ChatUtils

  @topic "ai_chat"

  def new_user_message(text_content) do
    GenServer.cast(__MODULE__, {:user_message, text_content})
  end

  def get_conversation do
    GenServer.call(__MODULE__, :get_conversation)
  end

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{
        messages: [],
        streaming_response: nil,
        turn: :user
      },
      name: __MODULE__
    )
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({:user_message, text_content}, state) do
    new_message = %{role: :user, content: text_content}
    broadcast({:user_chat_message, new_message})
    new_state = %{state | messages: state.messages ++ [new_message], turn: :assistant}
    request_ai_response(self(), new_state.messages)
    {:noreply, new_state}
  end

  def handle_info({:start_new_ai_response, id}, state) do
    starting_response = %{id: id, reasoning_content: "", content: ""}
    broadcast({:start_ai_response_stream, starting_response})

    {:noreply, %{state | streaming_response: starting_response}}
  end

  def handle_info(
        msg,
        %{streaming_response: %{id: current_id}} = state
      )
      when is_tuple(msg) and tuple_size(msg) in [2, 3] and elem(msg, 1) != current_id do
    Logger.warning(
      "Received #{elem(msg, 0)} for id #{elem(msg, 1)} but current streaming response is for id #{current_id}"
    )

    {:noreply, state}
  end

  def handle_info({:ai_reasoning_chunk, _id, reasoning_content}, state) do
    broadcast({:reasoning_chunk_content, reasoning_content})

    {:noreply,
     %{
       state
       | streaming_response: %{
           state.streaming_response
           | reasoning_content: state.streaming_response.reasoning_content <> reasoning_content
         }
     }}
  end

  def handle_info({:ai_text_chunk, _id, text_content}, state) do
    broadcast({:text_chunk_content, text_content})

    {:noreply,
     %{
       state
       | streaming_response: %{
           state.streaming_response
           | content: state.streaming_response.content <> text_content
         }
     }}
  end

  def handle_info({:ai_stream_finish, _id}, state) do
    broadcast(:end_ai_response)

    final_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content
    }

    {:noreply,
     %{
       state
       | streaming_response: nil,
         messages: state.messages ++ [final_message],
         turn: :user
     }}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, @topic, msg)
end
