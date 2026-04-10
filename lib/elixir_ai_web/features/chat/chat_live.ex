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
         |> assign(ai_error: nil)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: "/")}

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
         |> assign(ai_error: nil)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full  rounded-lg">
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
        class={"flex-1 overflow-y-auto p-4 rounded-lg #{@background_color}"}
      >
        <%= if @messages == [] do %>
          <p class="text-sm text-center mt-4">No messages yet.</p>
        <% end %>
        <%= for item <- group_messages(@messages) do %>
          <%= case item do %>
            <% {:tool_exchange, tc, result} -> %>
              <.tool_message tool_call={tc} result={result} />
            <% {:plain, msg} -> %>
              <%= cond do %>
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
        <button type="submit" class="px-4 py-2 rounded text-sm border">
          Send
        </button>
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

  def handle_event("submit", %{"user_input" => user_input}, socket) when user_input != "" do
    ChatRunner.new_user_message(socket.assigns.conversation_name, user_input)
    {:noreply, assign(socket, user_input: "")}
  end

  def handle_event("approve_command", %{"ref" => ref_string}, socket) do
    ref = decode_ref(ref_string)
    ChatRunner.approval_decision(socket.assigns.conversation_name, ref, :approved)

    {:noreply, update(socket, :pending_approvals, &Enum.reject(&1, fn a -> a.ref == ref end))}
  end

  def handle_event("deny_command", %{"ref" => ref_string}, socket) do
    ref = decode_ref(ref_string)
    ChatRunner.approval_decision(socket.assigns.conversation_name, ref, :denied)

    {:noreply, update(socket, :pending_approvals, &Enum.reject(&1, fn a -> a.ref == ref end))}
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

    # Now sync streaming state if there's an active stream
    if conversation.streaming_response do
      send(self(), :sync_streaming)
    end

    {:noreply, socket}
  end

  def handle_info({:conversation_stream_message, msg}, socket) do
    ConversationStreamHandler.handle(msg, socket)
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

  def handle_info({:set_background_color, color}, socket) do
    Logger.info("setting background color to #{color}")
    {:noreply, assign(socket, background_color: color)}
  end

  def handle_info({:tool_approval_request, ref, command, reason}, socket) do
    approval = %{ref: ref, command: command, reason: reason, timestamp: DateTime.utc_now()}

    {:noreply,
     socket
     |> update(:pending_approvals, &[approval | &1])}
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
end
