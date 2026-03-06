defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  import ElixirAi.ChatUtils

  @topic "ai_chat"

  def new_user_message(text_content) do
    GenServer.cast(__MODULE__, {:user_message, text_content})
  end

  @spec get_conversation() :: any()
  def get_conversation do
    GenServer.call(__MODULE__, :get_conversation)
  end

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %{
        messages: [],
        streaming_response: nil,
        tools: tools()
      },
      name: __MODULE__
    )
  end

  def init(state) do
    {:ok, state}
  end

  def tools do
    [
      ai_tool(
        name: "store_thing",
        description: "store a key value pair in memory",
        function: &ElixirAi.ToolTesting.hold_thing/1,
        parameters: ElixirAi.ToolTesting.hold_thing_params()
      ),
      ai_tool(
        name: "read_thing",
        description: "read a key value pair that was previously stored with store_thing",
        function: &ElixirAi.ToolTesting.get_thing/1,
        parameters: ElixirAi.ToolTesting.get_thing_params()
      )
    ]
  end

  def handle_cast({:user_message, text_content}, state) do
    new_message = %{role: :user, content: text_content}
    broadcast({:user_chat_message, new_message})
    new_state = %{state | messages: state.messages ++ [new_message]}

    request_ai_response(self(), new_state.messages, state.tools)
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
    Logger.info(
      "AI stream finished for id #{state.streaming_response.id}, broadcasting end of AI response"
    )

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
         messages: state.messages ++ [final_message]
     }}
  end

  def handle_info(
        {:ai_tool_call_start, _id, {tool_name, tool_args_start, tool_index, tool_call_id}},
        state
      ) do
    Logger.info("AI started tool call #{tool_name}")

    new_streaming_response = %{
      state.streaming_response
      | tool_calls:
          state.streaming_response.tool_calls ++
            [
              %{
                name: tool_name,
                arguments: tool_args_start,
                index: tool_index,
                id: tool_call_id
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

  def handle_info({:ai_tool_call_end, _id}, state) do
    Logger.info("ending tool call with tools: #{inspect(state.streaming_response.tool_calls)}")

    tool_calls =
      Enum.map(state.streaming_response.tool_calls, fn tool_call ->
        case Jason.decode(tool_call.arguments) do
          {:ok, decoded_args} ->
            tool = state.tools |> Enum.find(fn t -> t.name == tool_call.name end)

            res = tool.function.(decoded_args)
            Map.put(tool_call, :result, res)

          {:error, e} ->
            Map.put(tool_call, :error, "Failed to decode tool arguments: #{inspect(e)}")
        end
      end)

    tool_request_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: tool_calls
    }

    result_messages =
      Enum.map(tool_calls, fn call ->
        if Map.has_key?(call, :result) do
          %{role: :tool, content: "#{inspect(call.result)}", tool_call_id: call.id}
        else
          %{role: :tool, content: "Error in #{call.name}: #{call.error}", tool_call_id: call.id}
        end
      end)

    new_messages = [tool_request_message] ++ result_messages

    Logger.info("All tool calls finished, broadcasting updated tool calls with results")
    broadcast({:tool_calls_finished, new_messages})

    request_ai_response(self(), state.messages ++ new_messages, state.tools)

    {:noreply, %{state | messages: state.messages ++ new_messages, streaming_response: nil}}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, @topic, msg)
end
