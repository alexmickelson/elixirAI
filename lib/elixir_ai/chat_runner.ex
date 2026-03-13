defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  import ElixirAi.ChatUtils, only: [ai_tool: 1]
  alias ElixirAi.{Conversation, Message}
  import ElixirAi.PubsubTopics

  defp via(name), do: {:via, Horde.Registry, {ElixirAi.ChatRegistry, name}}

  def new_user_message(name, text_content) do
    GenServer.cast(via(name), {:user_message, text_content})
  end

  @spec get_conversation(String.t()) :: any()
  def get_conversation(name) do
    GenServer.call(via(name), :get_conversation)
  end

  def get_streaming_response(name) do
    GenServer.call(via(name), :get_streaming_response)
  end

  def start_link(name: name) do
    GenServer.start_link(__MODULE__, name, name: via(name))
  end

  def init(name) do
    messages =
      case Conversation.find_id(name) do
        {:ok, conv_id} -> Message.load_for_conversation(conv_id, topic: conversation_message_topic(name))
        _ -> []
      end

    last_message = List.last(messages)

    if last_message && last_message.role == :user do
      Logger.info(
        "Last message role was #{last_message.role}, requesting AI response for conversation #{name}"
      )

      ElixirAi.ChatUtils.request_ai_response(self(), messages, tools(self(), name))
    end

    {:ok,
     %{
       name: name,
       messages: messages,
       streaming_response: nil,
       pending_tool_calls: [],
       tools: tools(self(), name),
       ai_provider_url: Application.get_env(:elixir_ai, :ai_provider_url),
       ai_model: Application.get_env(:elixir_ai, :ai_model),
       ai_token: Application.get_env(:elixir_ai, :ai_token)
     }}
  end

  def tools(server, name) do
    [
      ai_tool(
        name: "store_thing",
        description: "store a key value pair in memory",
        function: &ElixirAi.ToolTesting.hold_thing/1,
        parameters: ElixirAi.ToolTesting.hold_thing_params(),
        server: server
      ),
      ai_tool(
        name: "read_thing",
        description: "read a key value pair that was previously stored with store_thing",
        function: &ElixirAi.ToolTesting.get_thing/1,
        parameters: ElixirAi.ToolTesting.get_thing_params(),
        server: server
      ),
      ai_tool(
        name: "set_background_color",
        description:
          "set the background color of the chat interface, accepts specified tailwind colors",
        function: fn %{"color" => color} ->
          Phoenix.PubSub.broadcast(
            ElixirAi.PubSub,
            chat_topic(name),
            {:set_background_color, color}
          )
        end,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "color" => %{
              "type" => "string",
              "enum" => ElixirAiWeb.ChatLive.valid_background_colors()
            }
          },
          "required" => ["color"]
        },
        server: server
      )
    ]
  end

  def handle_cast({:user_message, text_content}, state) do
    new_message = %{role: :user, content: text_content}
    broadcast_ui(state.name, {:user_chat_message, new_message})
    store_message(state.name, new_message)
    new_state = %{state | messages: state.messages ++ [new_message]}

    ElixirAi.ChatUtils.request_ai_response(self(), new_state.messages, state.tools)
    {:noreply, new_state}
  end

  def handle_info({:start_new_ai_response, id}, state) do
    starting_response = %{id: id, reasoning_content: "", content: "", tool_calls: []}
    broadcast_ui(state.name, {:start_ai_response_stream, starting_response})

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
    broadcast_ui(state.name, {:reasoning_chunk_content, reasoning_content})

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
    broadcast_ui(state.name, {:text_chunk_content, text_content})

    {:noreply,
     %{
       state
       | streaming_response: %{
           state.streaming_response
           | content: state.streaming_response.content <> text_content
         }
     }}
  end

  def handle_info({:ai_text_stream_finish, _id}, state) do
    Logger.info(
      "AI stream finished for id #{state.streaming_response.id}, broadcasting end of AI response"
    )

    final_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: state.streaming_response.tool_calls
    }

    broadcast_ui(state.name, {:end_ai_response, final_message})
    store_message(state.name, final_message)

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

  def handle_info({:ai_tool_call_end, id}, state) do
    # Logger.info("ending tool call with tools: #{inspect(state.streaming_response.tool_calls)}")

    tool_request_message = %{
      role: :assistant,
      content: state.streaming_response.content,
      reasoning_content: state.streaming_response.reasoning_content,
      tool_calls: state.streaming_response.tool_calls
    }

    broadcast_ui(state.name, {:tool_request_message, tool_request_message})

    {failed_call_messages, pending_call_ids} =
      Enum.reduce(state.streaming_response.tool_calls, {[], []}, fn tool_call,
                                                                    {failed, pending} ->
        with {:ok, decoded_args} <- Jason.decode(tool_call.arguments),
             tool when not is_nil(tool) <-
               Enum.find(state.tools, fn t -> t.name == tool_call.name end) do
          tool.run_function.(id, tool_call.id, decoded_args)
          {failed, [tool_call.id | pending]}
        else
          {:error, e} ->
            error_msg = "Failed to decode tool arguments: #{inspect(e)}"
            Logger.error("Tool call #{tool_call.name} failed: #{error_msg}")
            {[%{role: :tool, content: error_msg, tool_call_id: tool_call.id} | failed], pending}

          nil ->
            error_msg = "No tool definition found for #{tool_call.name}"
            Logger.error(error_msg)
            {[%{role: :tool, content: error_msg, tool_call_id: tool_call.id} | failed], pending}
        end
      end)

    store_message(state.name, [tool_request_message] ++ failed_call_messages)

    {:noreply,
     %{
       state
       | messages: state.messages ++ [tool_request_message] ++ failed_call_messages,
         pending_tool_calls: pending_call_ids
     }}
  end

  def handle_info({:tool_response, _id, tool_call_id, result}, state) do
    new_message = %{role: :tool, content: inspect(result), tool_call_id: tool_call_id}

    broadcast_ui(state.name, {:one_tool_finished, new_message})
    store_message(state.name, new_message)

    new_pending_tool_calls =
      Enum.filter(state.pending_tool_calls, fn id -> id != tool_call_id end)

    new_streaming_response =
      case new_pending_tool_calls do
        [] ->
          nil

        _ ->
          state.streaming_response
      end

    if new_pending_tool_calls == [] do
      broadcast_ui(state.name, :tool_calls_finished)
      ElixirAi.ChatUtils.request_ai_response(self(), state.messages ++ [new_message], state.tools)
    end

    {:noreply,
     %{
       state
       | pending_tool_calls: new_pending_tool_calls,
         streaming_response: new_streaming_response,
         messages: state.messages ++ [new_message]
     }}
  end

  def handle_info({:ai_request_error, reason}, state) do
    Logger.error("AI request error: #{inspect(reason)}")
    broadcast_ui(state.name, {:ai_request_error, reason})
    {:noreply, %{state | streaming_response: nil, pending_tool_calls: []}}
  end

  def handle_call(:get_conversation, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_streaming_response, _from, state) do
    {:reply, state.streaming_response, state}
  end

  defp broadcast_ui(name, msg), do: Phoenix.PubSub.broadcast(ElixirAi.PubSub, chat_topic(name), msg)

  defp store_message(name, messages) when is_list(messages) do
    Enum.each(messages, &store_message(name, &1))
    messages
  end

  defp store_message(name, message) do
    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      conversation_message_topic(name),
      {:store_message, name, message}
    )

    message
  end
end
