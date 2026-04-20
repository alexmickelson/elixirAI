defmodule ElixirAiWeb.ChatLive do
  use ElixirAiWeb, :live_view
  use ElixirAi.AiControllable
  require Logger
  import ElixirAiWeb.Spinner
  import ElixirAiWeb.UserMessage
  import ElixirAiWeb.AssistantMessage
  import ElixirAiWeb.ToolMessages
  import ElixirAiWeb.ChatProviderDisplay
  alias ElixirAi.{AiProvider, ChatRunner, ConversationManager}
  alias ElixirAiWeb.ConversationStreamHandler
  import ElixirAi.PubsubTopics

  @impl ElixirAi.AiControllable
  def ai_tools do
    [
      %{
        name: "set_user_input",
        description:
          "Set the text in the chat input field. Use this to pre-fill a message for the user. " <>
            "The user will still need to press Send (or you can describe what you filled in).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "text" => %{
              "type" => "string",
              "description" => "The text to place in the chat input field"
            }
          },
          "required" => ["text"]
        }
      }
    ]
  end

  @impl ElixirAi.AiControllable
  def handle_ai_tool_call("set_user_input", %{"text" => text}, socket) do
    {"user input set to: #{text}", assign(socket, user_input: text)}
  end

  def handle_ai_tool_call(_tool_name, _args, socket) do
    {"unknown tool", socket}
  end

  @impl Phoenix.LiveView
  def mount(%{"name" => name}, _session, socket) do
    case ConversationManager.open_conversation(name) do
      {:ok, %{runner_pid: pid}} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(ElixirAi.PubSub, chat_topic(name))
          Phoenix.PubSub.subscribe(ElixirAi.PubSub, mcp_topic())
          Phoenix.PubSub.subscribe(ElixirAi.PubSub, conversations_topic())
          :pg.join(ElixirAi.LiveViewPG, {:liveview, __MODULE__}, self())
          ChatRunner.register_liveview_pid_direct(pid, self())
          send(self(), :load_conversation)
        end

        {:ok,
         socket
         |> assign(conversation_name: name)
         |> assign(runner_pid: pid)
         |> assign(user_input: "")
         |> assign(messages: [])
         |> assign(streaming_response: nil)
         |> assign(background_color: "bg-seafoam-950/30")
         |> assign(pending_approvals: [])
         |> assign(provider: nil)
         |> assign(providers: AiProvider.all())
         |> assign(db_error: nil)
         |> assign(ai_error: nil)
         |> assign(runner_status: nil)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: "/")}

      {:error, :service_unavailable} ->
        {:ok,
         socket
         |> assign(conversation_name: name)
         |> assign(runner_pid: nil)
         |> assign(user_input: "")
         |> assign(messages: [])
         |> assign(streaming_response: nil)
         |> assign(background_color: "bg-seafoam-950/30")
         |> assign(pending_approvals: [])
         |> assign(provider: nil)
         |> assign(providers: AiProvider.all())
         |> assign(
           db_error:
             "The conversation service is not available. Please wait a moment and refresh."
         )
         |> assign(ai_error: nil)
         |> assign(runner_status: nil)}

      {:error, reason} ->
        Logger.error("Failed to start conversation #{name}: #{inspect(reason)}")

        {:ok,
         socket
         |> assign(conversation_name: name)
         |> assign(runner_pid: nil)
         |> assign(user_input: "")
         |> assign(messages: [])
         |> assign(streaming_response: nil)
         |> assign(background_color: "bg-seafoam-950/30")
         |> assign(pending_approvals: [])
         |> assign(provider: nil)
         |> assign(providers: AiProvider.all())
         |> assign(db_error: Exception.format(:error, reason))
         |> assign(ai_error: nil)
         |> assign(runner_status: nil)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full rounded-lg relative">
      <div class="px-4 py-3 font-semibold flex items-center gap-3">
        <.link navigate={~p"/"} class="text-seafoam-700 hover:text-seafoam-400 transition-colors">
          ←
        </.link>
        <span class="flex-1">{@conversation_name}</span>
        <.chat_provider_display provider={@provider} providers={@providers} />
      </div>
      <%= if @db_error do %>
        <div class="mx-4 mt-2 px-3 py-2 rounded text-sm text-red-400 bg-red-950/40" role="alert">
          Database error: {@db_error}
        </div>
      <% end %>
      <%= if @ai_error do %>
        <div class="mx-4 mt-2 px-3 py-2 rounded text-sm text-red-400 bg-red-950/40" role="alert">
          AI error: {@ai_error}
        </div>
      <% end %>
      <div
        id="chat-messages"
        phx-hook="ScrollBottom"
        class={"flex-1 overflow-y-auto flex flex-col-reverse rounded-lg #{@background_color}"}
      >
        <div class="flex flex-col p-4">
          <%= if @messages == [] do %>
            <p class="text-sm text-center mt-4">No messages yet.</p>
          <% end %>
          <%= for item <- group_messages(@messages) do %>
            <%= case item do %>
              <% {:tool_exchange, tc, result} -> %>
                <.tool_message tool_call={tc} result={result} />
              <% {:plain, msg} -> %>
                <%= cond do %>
                  <% msg.role == :error -> %>
                    <.error_message content={msg.content} />
                  <% msg.role == :user -> %>
                    <.user_message content={Map.get(msg, :content) || ""} />
                  <% true -> %>
                    <.assistant_message
                      content={Map.get(msg, :content) || ""}
                      reasoning_content={Map.get(msg, :reasoning_content)}
                      tool_calls={Map.get(msg, :tool_calls) || []}
                      input_tokens={Map.get(msg, :input_tokens)}
                      output_tokens={Map.get(msg, :output_tokens)}
                      tokens_per_second={Map.get(msg, :tokens_per_second)}
                      interrupted={Map.get(msg, :interrupted) || false}
                    />
                <% end %>
            <% end %>
          <% end %>
          <%= for approval <- @pending_approvals do %>
            <div class="mb-2 rounded-lg border border-amber-800/40 bg-amber-950/30 px-4 py-3">
              <p class="text-xs font-semibold uppercase tracking-wide text-amber-400">
                Command requires approval
              </p>
              <div
                id={"approval-reason-#{encode_ref(approval.ref)}"}
                phx-hook="MarkdownRender"
                phx-update="ignore"
                data-md={approval.reason}
                class="mt-0.5 text-xs text-amber-600/80 markdown"
              >
              </div>
              <pre class="mt-2 overflow-x-auto rounded bg-black/30 px-3 py-2 text-xs font-mono text-amber-300/80"><%= approval.command %></pre>
              <div class="mt-3 flex gap-2">
                <button
                  phx-click="approve_command"
                  phx-value-ref={encode_ref(approval.ref)}
                  class="rounded border border-seafoam-700/50 px-3 py-1.5 text-xs text-seafoam-300 transition-colors hover:bg-seafoam-900/40"
                >
                  Allow
                </button>
                <button
                  phx-click="deny_command"
                  phx-value-ref={encode_ref(approval.ref)}
                  class="rounded border border-red-800/50 px-3 py-1.5 text-xs text-red-400 transition-colors hover:bg-red-950/40"
                >
                  Deny
                </button>
              </div>
            </div>
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
      </div>
      <.runner_status_indicator status={@runner_status} />
      <form class="p-3 flex gap-2 items-center" phx-submit="submit" phx-change="update_user_input">
        <input
          type="text"
          name="user_input"
          value={@user_input}
          class="flex-1 rounded px-3 py-2 text-sm focus:outline-none focus:ring-2"
        />
        <.live_component
          module={ElixirAiWeb.ChatToolsLive}
          id="chat-tools"
          conversation_name={@conversation_name}
          runner_pid={assigns[:runner_pid]}
        />
        <%= if runner_active?(@runner_status) do %>
          <button
            type="button"
            phx-click="stop_conversation"
            class="px-4 py-2 rounded text-sm border border-red-800/50 text-red-400 hover:bg-red-950/40 transition-colors"
          >
            Stop
          </button>
        <% else %>
          <%= if @user_input == "" do %>
            <button
              type="submit"
              class="px-4 py-2 rounded text-sm border border-blue-800/50 text-blue-400 hover:bg-blue-950/40 transition-colors"
            >
              AI Turn
            </button>
          <% else %>
            <button type="submit" class="px-4 py-2 rounded text-sm border">
              Send
            </button>
          <% end %>
        <% end %>
      </form>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("update_user_input", %{"user_input" => user_input}, socket) do
    {:noreply, assign(socket, user_input: user_input)}
  end

  def handle_event("change_provider", %{"id" => provider_id}, socket) do
    case ChatRunner.set_provider(socket.assigns.conversation_name, provider_id) do
      {:ok, provider} -> {:noreply, assign(socket, provider: provider)}
      _error -> {:noreply, socket}
    end
  end

  def handle_event("submit", %{"user_input" => ""}, socket) do
    if runner_active?(socket.assigns.runner_status) do
      {:noreply, socket}
    else
      ChatRunner.ai_turn(socket.assigns.conversation_name)
      {:noreply, socket}
    end
  end

  def handle_event("submit", %{"user_input" => user_input}, socket) when user_input != "" do
    if runner_active?(socket.assigns.runner_status) do
      {:noreply, socket}
    else
      ChatRunner.new_user_message(socket.assigns.conversation_name, user_input)
      {:noreply, assign(socket, user_input: "")}
    end
  end

  def handle_event("stop_conversation", _params, socket) do
    ChatRunner.stop_conversation(socket.assigns.conversation_name)
    {:noreply, socket}
  end

  def handle_event("approve_command", %{"ref" => ref_string}, socket) do
    ref = decode_ref(ref_string)
    ChatRunner.approval_decision(socket.assigns.conversation_name, ref, :approved)
    remaining = Enum.reject(socket.assigns.pending_approvals, fn a -> a.ref == ref end)
    status = if remaining == [], do: :awaiting_tools, else: :pending_approval

    {:noreply,
     socket
     |> assign(pending_approvals: remaining)
     |> assign(runner_status: status)}
  end

  def handle_event("deny_command", %{"ref" => ref_string}, socket) do
    ref = decode_ref(ref_string)
    ChatRunner.approval_decision(socket.assigns.conversation_name, ref, :denied)
    remaining = Enum.reject(socket.assigns.pending_approvals, fn a -> a.ref == ref end)
    status = if remaining == [], do: :awaiting_tools, else: :pending_approval

    {:noreply,
     socket
     |> assign(pending_approvals: remaining)
     |> assign(runner_status: status)}
  end

  def handle_info(
        :load_conversation,
        %{assigns: %{runner_pid: pid, conversation_name: name}} = socket
      ) do
    conversation = GenServer.call(pid, {:conversation, :get_conversation})
    pending_approvals = ChatRunner.get_pending_approvals(name)

    socket =
      socket
      |> assign(messages: conversation.messages)
      |> assign(streaming_response: conversation.streaming_response)
      |> assign(provider: conversation.provider)
      |> assign(pending_approvals: pending_approvals)
      |> assign(runner_status: conversation.current_status)
      |> push_event("scroll_to_bottom", %{})

    # Now sync streaming state if there's an active stream
    if conversation.streaming_response do
      send(self(), :sync_streaming)
    end

    {:noreply, socket}
  end

  def handle_info({:conversation_stream_message, msg}, socket) do
    {:noreply, updated} = ConversationStreamHandler.handle(msg, socket)

    {:noreply,
     assign(updated, runner_status: derive_runner_status(msg, socket.assigns.runner_status))}
  end

  def handle_info(:sync_streaming, %{assigns: %{runner_pid: pid}} = socket)
      when is_pid(pid) do
    case GenServer.call(pid, {:conversation, :get_streaming_response}) do
      nil ->
        {:noreply, assign(socket, streaming_response: nil)}

      %{content: content, reasoning_content: reasoning_content} = snapshot ->
        socket =
          socket
          |> assign(streaming_response: snapshot)
          |> then(fn s ->
            if content != "", do: push_event(s, "md_chunk", %{chunk: content}), else: s
          end)
          |> then(fn s ->
            if reasoning_content != "",
              do: push_event(s, "reasoning_chunk", %{chunk: reasoning_content}),
              else: s
          end)
          |> push_event("scroll_to_bottom", %{})

        {:noreply, socket}
    end
  end

  def handle_info(:sync_streaming, socket), do: {:noreply, socket}

  def handle_info({:liveview_tool_call, "set_background_color", %{"color" => color}}, socket) do
    {:noreply, assign(socket, background_color: color)}
  end

  def handle_info({:liveview_tool_call, "navigate_to", %{"path" => path}}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_info({:liveview_tool_call, _tool_name, _args}, socket) do
    {:noreply, socket}
  end

  def handle_info({:mcp_tools_updated, _tools}, socket) do
    send_update(ElixirAiWeb.ChatToolsLive, id: "chat-tools", mcp_tools_updated: true)
    {:noreply, socket}
  end

  def handle_info({:conversation_deleted, name}, socket) do
    if name == socket.assigns.conversation_name do
      {:noreply, push_navigate(socket, to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:set_background_color, color}, socket) do
    Logger.info("setting background color to #{color}")
    {:noreply, assign(socket, background_color: color)}
  end

  def handle_info({:tool_approval_request, ref, command, reason}, socket) do
    approval = %{ref: ref, command: command, reason: reason, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> update(:pending_approvals, &[approval | &1])
     |> assign(runner_status: :pending_approval)
     |> push_event("scroll_to_bottom", %{})}
  end

  @impl Phoenix.LiveView
  def terminate(_reason, %{assigns: %{conversation_name: name}} = socket) do
    if connected?(socket) do
      ChatRunner.deregister_liveview_pid(name, self())
    end

    :ok
  end

  defp encode_ref(ref), do: ref |> :erlang.term_to_binary() |> Base.url_encode64()

  defp decode_ref(string), do: string |> Base.url_decode64!() |> :erlang.binary_to_term([:safe])

  defp derive_runner_status(msg, current) do
    case msg do
      {:user_chat_message, _} -> :generating_ai_response
      {:start_ai_response_stream, _} -> :generating_ai_response
      {:end_ai_response, _} -> :idle
      {:tool_request_message, _} -> :awaiting_tools
      :tool_calls_finished -> :generating_ai_response
      {:ai_request_error, _} -> :error
      {:inline_error_message, _} -> :error
      :recovery_restart -> :generating_ai_response
      :stopped -> :idle
      {:stopped, _} -> :idle
      _ -> current
    end
  end

  defp runner_active?(status),
    do: status in [:generating_ai_response, :awaiting_tools, :pending_approval, :initial_startup]

  attr :status, :atom, default: nil

  defp runner_status_indicator(assigns) do
    ~H"""
    <%= if @status not in [nil, :idle] do %>
      <div class="absolute bottom-14 right-3 pointer-events-none select-none z-10">
        <div class={[
          "flex items-center gap-1.5 px-2 py-1 rounded-full text-[11px] backdrop-blur-sm border",
          runner_status_classes(@status)
        ]}>
          <%= case @status do %>
            <% s when s in [:initial_startup, :generating_ai_response] -> %>
              <svg class="w-3 h-3 animate-spin shrink-0" fill="none" viewBox="0 0 24 24">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="3"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
            <% :awaiting_tools -> %>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3 h-3 shrink-0 animate-pulse"
              >
                <path
                  fill-rule="evenodd"
                  d="M14.5 10a4.5 4.5 0 0 0 4.284-5.882c-.105-.324-.51-.391-.752-.15L15.34 6.66a.454.454 0 0 1-.493.11 3.01 3.01 0 0 1-1.618-1.616.455.455 0 0 1 .11-.494l2.694-2.692c.24-.241.174-.647-.15-.752a4.5 4.5 0 0 0-5.873 4.575c.055.873-.128 1.808-.8 2.368l-7.23 6.024a2.724 2.724 0 1 0 3.837 3.837l6.024-7.23c.56-.672 1.495-.855 2.368-.8.096.007.193.01.291.01ZM5 16a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
                  clip-rule="evenodd"
                />
              </svg>
            <% :pending_approval -> %>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3 h-3 shrink-0"
              >
                <path
                  fill-rule="evenodd"
                  d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
                  clip-rule="evenodd"
                />
              </svg>
            <% :error -> %>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3 h-3 shrink-0"
              >
                <path
                  fill-rule="evenodd"
                  d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM8.28 7.22a.75.75 0 0 0-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 1 0 1.06 1.06L10 11.06l1.72 1.72a.75.75 0 1 0 1.06-1.06L11.06 10l1.72-1.72a.75.75 0 0 0-1.06-1.06L10 8.94 8.28 7.22Z"
                  clip-rule="evenodd"
                />
              </svg>
          <% end %>
          <span class="font-medium">{runner_status_label(@status)}</span>
        </div>
      </div>
    <% end %>
    """
  end

  defp runner_status_classes(:pending_approval),
    do: "bg-amber-950/70 border-amber-800/40 text-amber-400"

  defp runner_status_classes(:error),
    do: "bg-red-950/70 border-red-800/40 text-red-400"

  defp runner_status_classes(_),
    do: "bg-seafoam-950/70 border-seafoam-800/40 text-seafoam-400"

  defp runner_status_label(:initial_startup), do: "starting up"
  defp runner_status_label(:generating_ai_response), do: "thinking"
  defp runner_status_label(:awaiting_tools), do: "running tools"
  defp runner_status_label(:pending_approval), do: "awaiting approval"
  defp runner_status_label(:error), do: "error"
  defp runner_status_label(_), do: ""
end
