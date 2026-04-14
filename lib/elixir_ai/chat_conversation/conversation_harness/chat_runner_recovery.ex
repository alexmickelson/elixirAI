defmodule ElixirAi.ChatRunner.Recovery do
  @moduledoc """
  Handles the GenServer continue :load_from_db phase for ChatRunner — loading
  persisted conversation state from the database and deciding how to resume
  mid-conversation (restart an in-progress AI response, re-raise pending tool
  approvals, or leave the conversation idle/stopped).
  """

  require Logger
  alias ElixirAi.{AiTools, Conversation, Message, SystemPrompts}
  import ElixirAi.PubsubTopics
  import ElixirAi.ChatRunner.OutboundHelpers

  def load_and_resume(%{name: name} = state) do
    # Run all DB lookups concurrently — these are independent queries
    tasks = %{
      messages_and_id:
        Task.async(fn ->
          case Conversation.find_id(name) do
            {:ok, conv_id} ->
              {conv_id,
               Message.load_for_conversation(conv_id, topic: conversation_message_topic(name))}

            _ ->
              {nil, []}
          end
        end),
      provider: Task.async(fn -> Conversation.find_provider(name) end),
      allowed_tools: Task.async(fn -> Conversation.find_allowed_tools(name) end),
      tool_choice: Task.async(fn -> Conversation.find_tool_choice(name) end),
      category: Task.async(fn -> Conversation.find_category(name) end),
      stopped: Task.async(fn -> Conversation.find_stopped(name) end)
    }

    {conversation_id, messages} = Task.await(tasks.messages_and_id, 10_000)
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

    stopped =
      case Task.await(tasks.stopped, 5_000) do
        {:ok, s} -> s
        _ -> false
      end

    server_tools = AiTools.build_server_tools(self(), allowed_tools)
    liveview_tools = AiTools.build_liveview_tools(self(), allowed_tools)

    {recovered_tool_call_ids, recovery_task_pid} =
      recover_pending_state(
        name,
        messages,
        last_message,
        system_prompt,
        server_tools,
        liveview_tools,
        provider,
        tool_choice,
        stopped,
        state.response_format
      )

    recovered_status = derive_status(stopped, last_message, recovered_tool_call_ids)

    {:noreply,
     %{
       state
       | conversation_id: conversation_id,
         messages: messages,
         system_prompt: system_prompt,
         allowed_tools: allowed_tools,
         tool_choice: tool_choice,
         server_tools: server_tools,
         liveview_tools: liveview_tools,
         provider: provider,
         pending_tool_calls: recovered_tool_call_ids,
         current_status: recovered_status,
         stopped: stopped,
         ai_task_pid: recovery_task_pid
     }}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Finds tool calls that were still awaiting approval when the server crashed,
  # re-raises them for the approval flow, and optionally fires a new AI request
  # if the last message implies generation should resume.
  defp recover_pending_state(
         name,
         messages,
         last_message,
         system_prompt,
         server_tools,
         liveview_tools,
         provider,
         tool_choice,
         stopped,
         response_format
       ) do
    pending_run_calls = find_unanswered_run_calls(messages)

    unless pending_run_calls == [] do
      Logger.info(
        "Recovering #{length(pending_run_calls)} pending approval(s) for conversation #{name}"
      )
    end

    Enum.each(pending_run_calls, fn tc ->
      args =
        case tc.arguments do
          a when is_map(a) -> a
          a when is_binary(a) -> Jason.decode!(a)
        end

      AiTools.recover_run_tool_call(self(), tc.id, args["command"] || args[:command])
    end)

    recovered_tool_call_ids = Enum.map(pending_run_calls, & &1.id)

    recovery_task_pid =
      maybe_restart_ai(
        name,
        messages,
        last_message,
        system_prompt,
        server_tools,
        liveview_tools,
        provider,
        tool_choice,
        stopped,
        response_format
      )

    {recovered_tool_call_ids, recovery_task_pid}
  end

  defp find_unanswered_run_calls(messages) do
    responded_tool_call_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    messages
    |> Enum.flat_map(fn
      %{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) ->
        Enum.filter(tool_calls, fn tc ->
          tc.name == "run" and
            Map.get(tc, :approval_decision) == nil and
            not MapSet.member?(responded_tool_call_ids, tc.id)
        end)

      _ ->
        []
    end)
  end

  defp maybe_restart_ai(
         name,
         messages,
         last_message,
         system_prompt,
         server_tools,
         liveview_tools,
         provider,
         tool_choice,
         stopped,
         response_format
       ) do
    restart_roles = [:user, :tool]

    if last_message && last_message.role in restart_roles && !stopped do
      Logger.info(
        "Last message role was #{last_message.role}, requesting AI response for conversation #{name}"
      )

      broadcast_ui(name, :recovery_restart)

      {:ok, pid} =
        ElixirAi.ChatUtils.request_ai_response(
          self(),
          messages_with_system_prompt(messages, system_prompt),
          server_tools ++ liveview_tools,
          provider,
          tool_choice,
          response_format
        )

      pid
    end
  end

  defp derive_status(stopped, last_message, recovered_tool_call_ids) do
    restart_roles = [:user, :tool]

    cond do
      stopped -> :stopped
      last_message && last_message.role in restart_roles -> :generating_ai_response
      recovered_tool_call_ids != [] -> :pending_approval
      true -> :idle
    end
  end
end
