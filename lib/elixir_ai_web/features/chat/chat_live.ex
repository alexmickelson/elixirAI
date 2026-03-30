defmodule ElixirAiWeb.ChatLive do
  use ElixirAiWeb, :live_view
  use ElixirAi.AiControllable
  require Logger
  import ElixirAiWeb.Spinner
  import ElixirAiWeb.ChatMessage
  import ElixirAiWeb.ChatProviderDisplay
  alias ElixirAi.{AiProvider, ChatRunner, ConversationManager}
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
        <%= for msg <- @messages do %>
          <%= cond do %>
            <% msg.role == :user -> %>
              <.user_message content={Map.get(msg, :content) || ""} />
            <% msg.role == :tool -> %>
              <.tool_result_message
                content={Map.get(msg, :content) || ""}
                tool_call_id={Map.get(msg, :tool_call_id) || ""}
              />
            <% true -> %>
              <.assistant_message
                content={Map.get(msg, :content) || ""}
                reasoning_content={Map.get(msg, :reasoning_content)}
                tool_calls={Map.get(msg, :tool_calls) || []}
              />
          <% end %>
        <% end %>
        <%= for approval <- @pending_approvals do %>
          <div class="bg-amber-50 border border-amber-300 rounded-lg p-4 mb-2">
            <div class="flex items-start gap-3">
              <div class="flex-shrink-0 text-amber-600">⚠️</div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-amber-800">Command requires approval</p>
                <p class="text-xs text-amber-600 mt-0.5">{approval.reason}</p>
                <pre class="mt-2 p-2 bg-amber-100 rounded text-sm font-mono text-amber-900 overflow-x-auto"><%= approval.command %></pre>
                <div class="mt-3 flex gap-2">
                  <button
                    phx-click="approve_command"
                    phx-value-ref={encode_ref(approval.ref)}
                    class="px-3 py-1.5 bg-green-600 text-white text-sm rounded hover:bg-green-700"
                  >
                    Allow
                  </button>
                  <button
                    phx-click="deny_command"
                    phx-value-ref={encode_ref(approval.ref)}
                    class="px-3 py-1.5 bg-red-600 text-white text-sm rounded hover:bg-red-700"
                  >
                    Deny
                  </button>
                </div>
              </div>
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
        %{assigns: %{runner_pid: pid, conversation_name: _name}} = socket
      ) do
    conversation = GenServer.call(pid, {:conversation, :get_conversation})

    socket =
      socket
      |> assign(messages: conversation.messages)
      |> assign(streaming_response: conversation.streaming_response)
      |> assign(provider: conversation.provider)

    # Now sync streaming state if there's an active stream
    if conversation.streaming_response do
      send(self(), :sync_streaming)
    end

    {:noreply, socket}
  end

  def handle_info(:recovery_restart, socket) do
    {:noreply, assign(socket, streaming_response: nil, ai_error: nil)}
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

  def handle_info({:user_chat_message, message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [message]))
     |> push_event("scroll_to_bottom", %{})}
  end

  def handle_info(
        {:start_ai_response_stream,
         %{id: _id, reasoning_content: "", content: ""} = starting_response},
        socket
      ) do
    {:noreply, assign(socket, streaming_response: starting_response)}
  end

  # chunk arrived before :start_ai_response_stream — fetch snapshot from runner and apply
  def handle_info(
        {:reasoning_chunk_content, reasoning_content},
        %{assigns: %{streaming_response: nil}} = socket
      ) do
    base = get_snapshot(socket) |> Map.update!(:reasoning_content, &(&1 <> reasoning_content))
    {:noreply, assign(socket, streaming_response: base)}
  end

  def handle_info({:reasoning_chunk_content, reasoning_content}, socket) do
    updated_response = %{
      socket.assigns.streaming_response
      | reasoning_content:
          socket.assigns.streaming_response.reasoning_content <> reasoning_content
    }

    # Update assign (controls toggle button visibility) and stream chunk to hook.
    {:noreply,
     socket
     |> assign(streaming_response: updated_response)
     |> push_event("reasoning_chunk", %{chunk: reasoning_content})}
  end

  def handle_info(
        {:text_chunk_content, text_content},
        %{assigns: %{streaming_response: nil}} = socket
      ) do
    base = get_snapshot(socket) |> Map.update!(:content, &(&1 <> text_content))
    {:noreply, assign(socket, streaming_response: base)}
  end

  def handle_info({:text_chunk_content, text_content}, socket) do
    updated_response = %{
      socket.assigns.streaming_response
      | content: socket.assigns.streaming_response.content <> text_content
    }

    # Update assign (accumulated for final message) and stream chunk to hook.
    {:noreply,
     socket
     |> assign(streaming_response: updated_response)
     |> push_event("md_chunk", %{chunk: text_content})}
  end

  def handle_info(:tool_calls_finished, socket) do
    # Logger.info("Received tool_calls_finished")

    {:noreply,
     socket
     |> assign(streaming_response: nil)}
  end

  def handle_info({:tool_request_message, tool_request_message}, socket) do
    # Tool calls are now finalized in @messages — clear streaming_response so
    # the streaming bubble doesn't render below the incoming tool results.
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [tool_request_message]))
     |> assign(streaming_response: nil)}
  end

  def handle_info({:one_tool_finished, tool_response}, socket) do
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

  def handle_info({:db_error, reason}, socket) do
    {:noreply, assign(socket, db_error: reason)}
  end

  def handle_info({:ai_request_error, reason}, socket) do
    error_message =
      case reason do
        "proxy error" <> _ ->
          "Could not connect to AI provider. Please check your proxy and provider settings."

        %{__struct__: mod, reason: r} ->
          "#{inspect(mod)}: #{inspect(r)}"

        msg when is_binary(msg) ->
          msg

        _ ->
          inspect(reason)
      end

    {:noreply, assign(socket, ai_error: error_message, streaming_response: nil)}
  end

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

  defp get_snapshot(%{assigns: %{runner_pid: pid}} = _socket) when is_pid(pid) do
    case GenServer.call(pid, {:conversation, :get_streaming_response}) do
      nil -> %{id: nil, content: "", reasoning_content: "", tool_calls: []}
      snapshot -> snapshot
    end
  end

  defp get_snapshot(socket) do
    ChatRunner.get_streaming_response(socket.assigns.conversation_name)
    |> case do
      nil -> %{id: nil, content: "", reasoning_content: "", tool_calls: []}
      snapshot -> snapshot
    end
  end

  defp encode_ref(ref), do: ref |> :erlang.term_to_binary() |> Base.url_encode64()

  defp decode_ref(string), do: string |> Base.url_decode64!() |> :erlang.binary_to_term([:safe])
end
