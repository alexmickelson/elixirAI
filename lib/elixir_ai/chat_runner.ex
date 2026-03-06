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

  def tools do
    %{
      "store_thing" => %{
        definition: ElixirAi.ToolTesting.store_thing_definition("store_thing"),
        function: &ElixirAi.ToolTesting.hold_thing/1
      },
      "read_thing" => %{
        definition: ElixirAi.ToolTesting.read_thing_definition("read_thing"),
        function: &ElixirAi.ToolTesting.get_thing/0
      }
    }
  end

  def handle_cast({:user_message, text_content}, state) do
    new_message = %{role: :user, content: text_content}
    broadcast({:user_chat_message, new_message})
    new_state = %{state | messages: state.messages ++ [new_message], turn: :assistant}

    tools =
      tools()
      |> Enum.map(fn {name, %{definition: definition}} -> {name, definition} end)
      |> Enum.into(%{})

    request_ai_response(self(), new_state.messages, tools)
    {:noreply, new_state}
  end

  def handle_info({:start_new_ai_response, id}, state) do
    starting_response = %{id: id, reasoning_content: "", content: "", tool_calls: []}
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
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: state.streaming_response.tool_calls
    }

    {:noreply,
     %{
       state
       | streaming_response: nil,
         messages: state.messages ++ [final_message],
         turn: :user
     }}
  end

  def handle_info({:ai_tool_call_start, _id, {tool_name, tool_args_start, tool_index}}, state) do
    Logger.info("AI started tool call #{tool_name}")

    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          state.streaming_response.tool_calls ++
            [
              %{
                name: tool_name,
                arguments: tool_args_start,
                index: tool_index
              }
            ]
    }

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle_info({:ai_tool_call_middle, _id, {tool_args_diff, tool_index}}, state) do
    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          Enum.map(state.streaming_response.tool_calls, fn
            %{
              arguments: existing_args,
              index: ^tool_index
            } = tool_call ->
              %{
                tool_call
                | arguments: existing_args <> tool_args_diff
              }

            other ->
              other
          end)
    }

    {:noreply, %{state | streaming_response: new_streaming_response}}
  end

  def handle_info({:ai_tool_call_end, _id, tool_index}, state) do
    tool_calls =
      Enum.map(state.streaming_response.tool_calls, fn
        %{
          arguments: existing_args,
          index: ^tool_index
        } = tool_call ->
          case Jason.decode(existing_args) do
            {:ok, decoded_args} ->
              tool_function = tools()[tool_call.name].function
              res = tool_function.(decoded_args)

              Map.put(tool_call, :result, res)

            {:error, e} ->
              Map.put(tool_call, :error, "Failed to decode tool arguments: #{inspect(e)}")
          end

        other ->
          other
      end)

    all_tool_calls_finished =
      Enum.all?(tool_calls, fn call ->
        Map.has_key?(call, :result) or Map.has_key?(call, :error)
      end)

    state =
      case all_tool_calls_finished do
        true ->
          Logger.info("All tool calls finished, broadcasting updated tool calls with results")

          new_message = %{
            role: :assistant,
            content: state.streaming_response.content,
            reasoning_content: state.streaming_response.reasoning_content,
            tool_calls: tool_calls
          }

          new_state = %{
            state
            | messages:
                state.messages ++
                  [
                    new_message
                  ],
              streaming_response: nil
          }

          broadcast({:tool_calls_finished, new_message})

        false ->
          %{
            state
            | streaming_response: %{
                state.streaming_response
                | tool_calls: tool_calls
              }
          }
      end

    {:noreply, state}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, @topic, msg)
end
