defmodule ElixirAiWeb.VoiceLive do
  use ElixirAiWeb, :live_view
  require Logger

  alias ElixirAiWeb.Voice.Recording
  alias ElixirAiWeb.Voice.VoiceConversation
  alias ElixirAi.{AiProvider, AiTools, ChatRunner, ConversationManager}
  import ElixirAi.PubsubTopics

  def mount(_params, session, socket) do
    voice_session_id = session["voice_session_id"]

    {:ok,
     assign(socket,
       state: :idle,
       transcription: nil,
       expanded: false,
       conversation_name: nil,
       messages: [],
       streaming_response: nil,
       runner_pid: nil,
       ai_error: nil,
       voice_session_id: voice_session_id
     ), layout: false}
  end

  def render(assigns) do
    ~H"""
    <div id="voice-control-hook" phx-hook="VoiceControl">
      <%= if not @expanded do %>
        <button
          phx-click="expand"
          title="Voice input (Ctrl+Space)"
          class="fixed top-4 right-4 z-50 p-2.5 rounded-full bg-seafoam-900/50 hover:bg-seafoam-800/80 border border-seafoam-700/50 hover:border-seafoam-600 text-seafoam-500/70 hover:text-seafoam-300 transition-all duration-200 opacity-50 hover:opacity-100"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-5 w-5"
            viewBox="0 0 24 24"
            fill="currentColor"
          >
            <path d="M12 1a4 4 0 0 1 4 4v7a4 4 0 0 1-8 0V5a4 4 0 0 1 4-4zm0 2a2 2 0 0 0-2 2v7a2 2 0 1 0 4 0V5a2 2 0 0 0-2-2zm-7 9a7 7 0 0 0 14 0h2a9 9 0 0 1-8 8.94V23h-2v-2.06A9 9 0 0 1 3 12H5z" />
          </svg>
        </button>
      <% else %>
        <div class={[
          "fixed top-4 right-4 z-50 bg-seafoam-900 border border-seafoam-800 rounded-2xl shadow-2xl flex flex-col backdrop-blur",
          if(@state == :transcribed, do: "w-96 max-h-[80vh]", else: "w-72")
        ]}>
          <%= if @state == :transcribed do %>
            <VoiceConversation.voice_conversation
              messages={@messages}
              streaming_response={@streaming_response}
              ai_error={@ai_error}
            />
          <% else %>
            <Recording.recording state={@state} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("expand", _params, socket) do
    {:noreply, assign(socket, expanded: true)}
  end

  def handle_event("minimize", _params, socket) do
    {:noreply, assign(socket, expanded: false)}
  end

  def handle_event("recording_started", _params, socket) do
    {:noreply, assign(socket, state: :recording, expanded: true)}
  end

  def handle_event("audio_recorded", %{"data" => base64, "mime_type" => mime_type}, socket) do
    case Base.decode64(base64) do
      {:ok, audio_binary} ->
        Logger.info(
          "VoiceLive: received #{byte_size(audio_binary)} bytes of audio (#{mime_type})"
        )

        ElixirAi.AudioProcessing.submit(audio_binary, mime_type, self())
        {:noreply, assign(socket, state: :processing)}

      :error ->
        Logger.error("VoiceLive: failed to decode base64 audio data")
        {:noreply, assign(socket, state: :idle)}
    end
  end

  def handle_event("recording_error", %{"reason" => reason}, socket) do
    Logger.warning("VoiceLive: recording error: #{reason}")
    {:noreply, assign(socket, state: :idle)}
  end

  def handle_event("dismiss_transcription", _params, socket) do
    name = socket.assigns.conversation_name

    if name do
      if socket.assigns.runner_pid do
        try do
          GenServer.call(
            socket.assigns.runner_pid,
            {:session, {:deregister_liveview_pid, self()}}
          )
        catch
          :exit, _ -> :ok
        end
      end

      Phoenix.PubSub.unsubscribe(ElixirAi.PubSub, chat_topic(name))
    end

    {:noreply,
     assign(socket,
       state: :idle,
       transcription: nil,
       expanded: false,
       conversation_name: nil,
       messages: [],
       streaming_response: nil,
       runner_pid: nil,
       ai_error: nil
     )}
  end

  # Transcription received — open conversation and send as user message
  def handle_info({:transcription_result, {:ok, text}}, socket) do
    socket = start_voice_conversation(socket, text)
    {:noreply, socket}
  end

  def handle_info({:transcription_result, {:error, reason}}, socket) do
    Logger.error("VoiceLive: transcription failed: #{inspect(reason)}")
    {:noreply, assign(socket, state: :idle)}
  end

  # --- Chat PubSub handlers (same pattern as ChatLive) ---

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

    {:noreply,
     socket
     |> assign(streaming_response: updated_response)
     |> push_event("md_chunk", %{chunk: text_content})}
  end

  def handle_info(:tool_calls_finished, socket) do
    {:noreply, assign(socket, streaming_response: nil)}
  end

  def handle_info({:tool_request_message, tool_request_message}, socket) do
    {:noreply, update(socket, :messages, &(&1 ++ [tool_request_message]))}
  end

  def handle_info({:one_tool_finished, tool_response}, socket) do
    {:noreply, update(socket, :messages, &(&1 ++ [tool_response]))}
  end

  def handle_info({:end_ai_response, final_message}, socket) do
    {:noreply,
     socket
     |> update(:messages, &(&1 ++ [final_message]))
     |> assign(streaming_response: nil)}
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

  def handle_info({:db_error, reason}, socket) do
    Logger.error("VoiceLive: db error: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_info({:liveview_tool_call, "navigate_to", %{"path" => path}}, socket) do
    {:noreply, push_event(socket, "navigate_to", %{path: path})}
  end

  def handle_info({:liveview_tool_call, _tool_name, _args}, socket) do
    {:noreply, socket}
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

        {:noreply, socket}
    end
  end

  def handle_info(:sync_streaming, socket), do: {:noreply, socket}

  def handle_info(:recovery_restart, socket) do
    {:noreply, assign(socket, streaming_response: nil, ai_error: nil)}
  end

  # --- Private helpers ---

  defp start_voice_conversation(socket, transcription) do
    existing_name = socket.assigns.conversation_name

    if existing_name do
      # Reuse the existing conversation — just re-open to get a fresh runner pid
      case ConversationManager.open_conversation(existing_name) do
        {:ok, conv} ->
          connect_and_send(socket, existing_name, conv, transcription)

        {:error, reason} ->
          assign(socket,
            state: :transcribed,
            ai_error: "Failed to reopen voice conversation: #{inspect(reason)}"
          )
      end
    else
      name = "voice-#{System.system_time(:second)}"

      case AiProvider.find_by_name("default") do
        {:ok, provider} ->
          case ConversationManager.create_conversation(name, provider.id, "voice") do
            {:ok, _pid} ->
              case ConversationManager.open_conversation(name) do
                {:ok, conv} ->
                  connect_and_send(socket, name, conv, transcription)

                {:error, reason} ->
                  assign(socket,
                    state: :transcribed,
                    ai_error: "Failed to open voice conversation: #{inspect(reason)}"
                  )
              end

            {:error, reason} ->
              assign(socket,
                state: :transcribed,
                ai_error: "Failed to create voice conversation: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          assign(socket,
            state: :transcribed,
            ai_error: "No default AI provider found: #{inspect(reason)}"
          )
      end
    end
  end

  defp connect_and_send(socket, name, conversation, transcription) do
    runner_pid = Map.get(conversation, :runner_pid)
    already_connected = socket.assigns.conversation_name == name

    try do
      if connected?(socket) and not already_connected do
        Phoenix.PubSub.subscribe(ElixirAi.PubSub, chat_topic(name))

        if runner_pid,
          do: GenServer.call(runner_pid, {:session, {:register_liveview_pid, self()}})

        # Discover and register page tools from AiControllable LiveViews
        if runner_pid do
          page_tools = discover_and_build_page_tools(socket, runner_pid)

          if page_tools != [] do
            # Use the direct pid rather than the registry name to avoid
            # Horde delta-CRDT sync lag on freshly-created processes.
            GenServer.call(runner_pid, {:session, {:register_page_tools, page_tools}})
          end
        end

        send(self(), :sync_streaming)
      end

      if runner_pid do
        GenServer.cast(runner_pid, {:conversation, {:user_message, transcription, nil}})
      else
        ChatRunner.new_user_message(name, transcription)
      end

      assign(socket,
        state: :transcribed,
        transcription: transcription,
        conversation_name: name,
        messages: conversation.messages,
        streaming_response: conversation.streaming_response,
        runner_pid: runner_pid,
        ai_error: nil
      )
    catch
      :exit, reason ->
        Logger.error("VoiceLive: failed to connect to conversation #{name}: #{inspect(reason)}")

        assign(socket,
          state: :transcribed,
          transcription: transcription,
          conversation_name: nil,
          ai_error: "Failed to connect to conversation: process unavailable"
        )
    end
  end

  defp get_snapshot(%{assigns: %{runner_pid: pid}}) when is_pid(pid) do
    case GenServer.call(pid, {:conversation, :get_streaming_response}) do
      nil -> %{id: nil, content: "", reasoning_content: "", tool_calls: []}
      snapshot -> snapshot
    end
  end

  defp get_snapshot(_socket) do
    %{id: nil, content: "", reasoning_content: "", tool_calls: []}
  end

  defp discover_and_build_page_tools(socket, runner_pid) do
    voice_session_id = socket.assigns.voice_session_id
    if voice_session_id == nil, do: throw(:no_session)

    page_pids =
      try do
        :pg.get_members(ElixirAi.PageToolsPG, {:page, voice_session_id})
      catch
        :error, _ -> []
      end

    # Ask each page LiveView for its tool specs
    Enum.each(page_pids, &send(&1, {:get_ai_tools, self()}))

    pids_and_specs =
      Enum.reduce(page_pids, [], fn page_pid, acc ->
        receive do
          {:ai_tools_response, ^page_pid, tools} ->
            [{page_pid, tools} | acc]
        after
          1_000 -> acc
        end
      end)

    AiTools.build_page_tools(runner_pid, pids_and_specs)
  catch
    :no_session -> []
  end
end
