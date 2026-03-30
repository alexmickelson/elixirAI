defmodule ElixirAi.ChatRunner do
  require Logger
  use GenServer
  alias ElixirAi.{AiTools, Conversation, Message, SystemPrompts}
  import ElixirAi.PubsubTopics
  import ElixirAi.ChatRunner.OutboundHelpers

  alias ElixirAi.ChatRunner.{
    ConversationCalls,
    ErrorHandler,
    LiveviewSession,
    StreamHandler,
    ToolConfig
  }

  @ai_stream_events [
    :ai_text_chunk,
    :ai_reasoning_chunk,
    :ai_text_stream_finish,
    :ai_tool_call_start,
    :ai_tool_call_middle,
    :ai_tool_call_end,
    :tool_response
  ]

  defp via(name), do: {:via, Horde.Registry, {ElixirAi.ChatRegistry, name}}

  def new_user_message(name, text_content, opts \\ []) do
    tool_choice = Keyword.get(opts, :tool_choice)
    GenServer.cast(via(name), {:conversation, {:user_message, text_content, tool_choice}})
  end

  def set_allowed_tools(name, tool_names) when is_list(tool_names) do
    GenServer.call(via(name), {:tool_config, {:set_allowed_tools, tool_names}})
  end

  def set_tool_choice(name, tool_choice) when tool_choice in ["auto", "none", "required"] do
    GenServer.call(via(name), {:tool_config, {:set_tool_choice, tool_choice}})
  end

  def set_provider(name, provider_id) when is_binary(provider_id) do
    GenServer.call(via(name), {:tool_config, {:set_provider, provider_id}})
  end

  def register_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:session, {:register_liveview_pid, liveview_pid}})
  end

  def deregister_liveview_pid(name, liveview_pid) when is_pid(liveview_pid) do
    GenServer.call(via(name), {:session, {:deregister_liveview_pid, liveview_pid}})
  end

  def register_page_tools(name, page_tools) when is_list(page_tools) do
    GenServer.call(via(name), {:session, {:register_page_tools, page_tools}})
  end

  def get_conversation(name) do
    GenServer.call(via(name), {:conversation, :get_conversation})
  end

  def get_streaming_response(name) do
    GenServer.call(via(name), {:conversation, :get_streaming_response})
  end

  def approval_decision(name, ref, decision) do
    GenServer.cast(via(name), {:approval_decision, ref, decision})
  end

  def start_link(name: name) do
    GenServer.start_link(__MODULE__, name, name: via(name))
  end

  def init(name) do
    Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversation_message_topic(name))
    :pg.join(ElixirAi.RunnerPG, {:runner, name}, self())

    {:ok,
     %{
       name: name,
       messages: [],
       system_prompt: nil,
       streaming_response: nil,
       pending_tool_calls: [],
       pending_approvals: %{},
       allowed_tools: AiTools.all_tool_names(),
       tool_choice: "auto",
       server_tools: [],
       liveview_tools: [],
       page_tools: [],
       provider: nil,
       liveview_pids: %{},
       loading: true
     }, {:continue, :load_from_db}}
  end

  def handle_continue(:load_from_db, %{name: name} = state) do
    # Run all DB lookups concurrently — these are independent queries
    tasks = %{
      messages:
        Task.async(fn ->
          case Conversation.find_id(name) do
            {:ok, conv_id} ->
              Message.load_for_conversation(conv_id, topic: conversation_message_topic(name))

            _ ->
              []
          end
        end),
      provider: Task.async(fn -> Conversation.find_provider(name) end),
      allowed_tools: Task.async(fn -> Conversation.find_allowed_tools(name) end),
      tool_choice: Task.async(fn -> Conversation.find_tool_choice(name) end),
      category: Task.async(fn -> Conversation.find_category(name) end)
    }

    messages = Task.await(tasks.messages, 10_000)
    last_message = List.last(messages)

    provider =
      case Task.await(tasks.provider, 5_000) do
        {:ok, p} -> p
        _ -> nil
      end

    allowed_tools =
      case Task.await(tasks.allowed_tools, 5_000) do
        {:ok, tools} -> tools
        _ -> AiTools.all_tool_names()
      end

    tool_choice =
      case Task.await(tasks.tool_choice, 5_000) do
        {:ok, tc} -> tc
        _ -> "auto"
      end

    system_prompt =
      case Task.await(tasks.category, 5_000) do
        {:ok, category} -> SystemPrompts.for_category(category)
        _ -> nil
      end

    server_tools = AiTools.build_server_tools(self(), allowed_tools)
    liveview_tools = AiTools.build_liveview_tools(self(), allowed_tools)

    if last_message && last_message.role == :user do
      Logger.info(
        "Last message role was #{last_message.role}, requesting AI response for conversation #{name}"
      )

      broadcast_ui(name, :recovery_restart)

      ElixirAi.ChatUtils.request_ai_response(
        self(),
        messages_with_system_prompt(messages, system_prompt),
        server_tools ++ liveview_tools,
        provider,
        tool_choice
      )
    end

    {:noreply,
     %{
       state
       | messages: messages,
         system_prompt: system_prompt,
         allowed_tools: allowed_tools,
         tool_choice: tool_choice,
         server_tools: server_tools,
         liveview_tools: liveview_tools,
         provider: provider,
         loading: false
     }}
  end

  def handle_cast({:conversation, inner}, state), do: ConversationCalls.handle_cast(inner, state)

  def handle_cast({:approval_decision, ref, decision}, state) do
    case Map.pop(state.pending_approvals, ref) do
      {nil, _} ->
        {:noreply, state}

      {pid, new_approvals} ->
        send(pid, {:approval_response, ref, decision})
        {:noreply, %{state | pending_approvals: new_approvals}}
    end
  end

  def handle_info(
        {:stream, msg},
        %{streaming_response: %{id: current_id}} = state
      )
      when is_tuple(msg) and tuple_size(msg) in [2, 3] and
             elem(msg, 0) in @ai_stream_events and elem(msg, 1) != current_id do
    Logger.warning(
      "Received #{elem(msg, 0)} for id #{inspect(elem(msg, 1))} but current streaming response is for id #{inspect(current_id)}"
    )

    {:noreply, state}
  end

  def handle_info({:stream, inner}, state), do: StreamHandler.handle(inner, state)
  def handle_info({:error, inner}, state), do: ErrorHandler.handle(inner, state)

  def handle_info({:register_pending_approval, ref, pid}, state) do
    {:noreply, put_in(state, [:pending_approvals, ref], pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: LiveviewSession.handle_down(ref, pid, reason, state)

  def handle_call({:conversation, inner}, from, state),
    do: ConversationCalls.handle_call(inner, from, state)

  def handle_call({:session, inner}, from, state),
    do: LiveviewSession.handle_call(inner, from, state)

  def handle_call({:tool_config, inner}, from, state),
    do: ToolConfig.handle_call(inner, from, state)
end
