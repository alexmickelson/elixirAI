defmodule ElixirAi.AiTools do
  @moduledoc """
  Central registry of all AI tools available to conversations.

  Tools are split into two categories:

  Tool names are stored in the `conversations` table (`allowed_tools` column)
  and act as the gate for which tools are active for a given conversation.
  """

  import ElixirAi.ChatUtils, only: [ai_tool: 1]
  import ElixirAi.PubsubTopics, only: [chat_topic: 1]
  require Logger

  @server_tool_names ["list_conversations", "run"]
  @liveview_tool_names ["set_background_color", "navigate_to"]
  @builtin_tool_names @server_tool_names ++ @liveview_tool_names

  def server_tool_names, do: @server_tool_names

  def liveview_tool_names, do: @liveview_tool_names

  @doc "Built-in tool names (server + liveview, no MCP)."
  def builtin_tool_names, do: @builtin_tool_names

  @doc "All tool names including dynamically discovered MCP tools."
  def all_tool_names do
    @builtin_tool_names ++ ElixirAi.Mcp.McpToolAdapter.all_mcp_tool_names()
  end

  def build_server_tools(server, allowed_names) do
    [list_conversations(server), run(server)]
    |> Enum.filter(&(&1.name in allowed_names))
  end

  def build_liveview_tools(server, allowed_names) do
    [set_background_color(server), navigate_to(server)]
    |> Enum.filter(&(&1.name in allowed_names))
  end

  def build_mcp_tools(server, allowed_names) do
    ElixirAi.Mcp.McpToolAdapter.build_allowed_mcp_tools(server, allowed_names)
  end

  @doc "Convenience wrapper — builds all allowed tools (server + liveview + mcp)."
  def build(server, allowed_names) do
    build_server_tools(server, allowed_names) ++
      build_liveview_tools(server, allowed_names) ++
      build_mcp_tools(server, allowed_names)
  end

  def recover_run_tool_call(server, tool_call_id, command) do
    Task.start_link(fn ->
      try do
        name = :sys.get_state(server).name
        topic = ElixirAi.PubsubTopics.conversation_message_topic(name)

        result =
          case ElixirAi.CommandApproval.classify(command) do
            {:auto_allow, justification} ->
              ElixirAi.Message.update_approval_decision(tool_call_id, "auto_allowed",
                justification: justification,
                topic: topic
              )

              Phoenix.PubSub.broadcast(
                ElixirAi.PubSub,
                chat_topic(name),
                {:conversation_stream_message,
                 {:tool_approval_updated, tool_call_id, "auto_allowed", justification}}
              )

              execute_command(command)

            {:needs_approval, justification} ->
              {decision, cmd_result} = request_approval(server, command, justification)

              ElixirAi.Message.update_approval_decision(tool_call_id, Atom.to_string(decision),
                justification: justification,
                topic: topic
              )

              Phoenix.PubSub.broadcast(
                ElixirAi.PubSub,
                chat_topic(name),
                {:conversation_stream_message,
                 {:tool_approval_updated, tool_call_id, Atom.to_string(decision), justification}}
              )

              cmd_result
          end

        send(server, {:stream, {:tool_response, nil, tool_call_id, result}})
      rescue
        e ->
          reason = Exception.format(:error, e, __STACKTRACE__)
          Logger.error("Recovery tool task crashed for #{tool_call_id}: #{reason}")
          send(server, {:stream, {:tool_response, nil, tool_call_id, {:error, reason}}})
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Server tools
  # ---------------------------------------------------------------------------

  def list_conversations(server) do
    ai_tool(
      name: "list_conversations",
      description: """
      Returns a list of all conversation names in the application.
      Always call this tool before navigating to a conversation page (e.g. /chat/:name)
      to ensure the conversation exists and to obtain the exact name to use in the path.
      """,
      function: fn _args ->
        names = ElixirAi.ConversationManager.list_conversations()
        {:ok, names}
      end,
      parameters: %{"type" => "object", "properties" => %{}},
      server: server
    )
  end

  def run(server) do
    schema = %{
      "type" => "function",
      "function" => %{
        "name" => "run",
        "description" => """
        Execute a command in the sandboxed container.

        Examples:
          cat log.txt | grep ERROR | wc -l
          curl -sL $URL -o data.csv && head -5 data.csv
          cat config.yaml || echo "not found, using defaults"

        MCP examples:
          mcp-cli list
          mcp-cli tools SERVER
          mcp-cli tools SERVER TOOL key="value"
          mcp-cli schema SERVER TOOL

        Use --help for command details (e.g. "grep --help", "mcp-cli tools --help").
        Large outputs are automatically truncated with a path to the full file.
        """,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" =>
                "Shell command to execute (e.g. \"ls -la\", \"cat file.txt | grep foo\")"
            }
          },
          "required" => ["command"]
        }
      }
    }

    run_function = fn current_message_id, tool_call_id, args ->
      Task.start_link(fn ->
        try do
          command = Map.fetch!(args, "command")
          name = :sys.get_state(server).name
          topic = ElixirAi.PubsubTopics.conversation_message_topic(name)

          approved? =
            case ElixirAi.CommandApproval.classify(command) do
              {:auto_allow, justification} ->
                ElixirAi.Message.update_approval_decision(tool_call_id, "auto_allowed",
                  justification: justification,
                  topic: topic
                )

                Phoenix.PubSub.broadcast(
                  ElixirAi.PubSub,
                  chat_topic(name),
                  {:conversation_stream_message,
                   {:tool_approval_updated, tool_call_id, "auto_allowed", justification}}
                )

                true

              {:needs_approval, justification} ->
                Phoenix.PubSub.broadcast(
                  ElixirAi.PubSub,
                  chat_topic(name),
                  {:conversation_stream_message,
                   {:tool_approval_updated, tool_call_id, "awaiting_approval", justification}}
                )

                decision = request_approval_decision(server, command, justification)

                ElixirAi.Message.update_approval_decision(tool_call_id, Atom.to_string(decision),
                  justification: justification,
                  topic: topic
                )

                Phoenix.PubSub.broadcast(
                  ElixirAi.PubSub,
                  chat_topic(name),
                  {:conversation_stream_message,
                   {:tool_approval_updated, tool_call_id, Atom.to_string(decision), justification}}
                )

                decision == :approved
            end

          if approved? do
            ElixirAi.CommandRunner.run_bash_stream(command, tool_call_id, self())
            forward_cmd_stream(server, current_message_id, tool_call_id)
          else
            denied_result = {:ok, "[denied] User declined: #{command}\n[exit:1 | 0ms]"}

            send(
              server,
              {:stream, {:tool_response, current_message_id, tool_call_id, denied_result}}
            )
          end
        rescue
          e ->
            reason = Exception.format(:error, e, __STACKTRACE__)
            Logger.error("Tool task crashed: #{reason}")

            send(
              server,
              {:stream, {:tool_response, current_message_id, tool_call_id, {:error, reason}}}
            )
        end
      end)
    end

    %{name: "run", definition: schema, run_function: run_function}
  end

  defp execute_command(command) do
    case ElixirAi.CommandRunner.run_bash(command) do
      {:ok, result} ->
        {:ok, ElixirAi.CommandRunner.Presentation.format(result)}

      {:error, reason} ->
        {:ok, "[error] runner unavailable: #{reason}\n[exit:1 | 0ms]"}
    end
  end

  defp forward_cmd_stream(server, current_message_id, tool_call_id) do
    receive do
      {:cmd_chunk, ^tool_call_id, chunk} ->
        send(server, {:stream, {:tool_response_chunk, current_message_id, tool_call_id, chunk}})
        forward_cmd_stream(server, current_message_id, tool_call_id)

      {:cmd_done, ^tool_call_id, exit_code, elapsed_ms} ->
        send(
          server,
          {:stream,
           {:tool_response_done, current_message_id, tool_call_id, exit_code, elapsed_ms}}
        )
    after
      # Generous timeout — the Port itself times out at 5 min
      310_000 ->
        send(
          server,
          {:stream,
           {:tool_response, current_message_id, tool_call_id, {:error, "stream receive timeout"}}}
        )
    end
  end

  defp request_approval(server, command, reason) do
    ref = make_ref()
    send(server, {:register_pending_approval, ref, self(), command, reason})

    name = :sys.get_state(server).name

    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      "ai_chat:#{name}",
      {:tool_approval_request, ref, command, reason}
    )

    receive do
      {:approval_response, ^ref, :approved} ->
        {:approved, execute_command(command)}

      {:approval_response, ^ref, :denied} ->
        {:denied, {:ok, "[denied] User declined: #{command}\n[exit:1 | 0ms]"}}
    after
      120_000 ->
        {:timed_out,
         {:ok, "[denied] Approval timed out after 2 minutes: #{command}\n[exit:1 | 0ms]"}}
    end
  end

  # Returns just the decision atom (:approved | :denied | :timed_out) without
  # executing the command — callers handle execution themselves.
  defp request_approval_decision(server, command, reason) do
    ref = make_ref()
    send(server, {:register_pending_approval, ref, self(), command, reason})

    name = :sys.get_state(server).name

    Phoenix.PubSub.broadcast(
      ElixirAi.PubSub,
      "ai_chat:#{name}",
      {:tool_approval_request, ref, command, reason}
    )

    receive do
      {:approval_response, ^ref, :approved} -> :approved
      {:approval_response, ^ref, :denied} -> :denied
    after
      120_000 -> :timed_out
    end
  end

  # ---------------------------------------------------------------------------
  # LiveView tools
  # ---------------------------------------------------------------------------

  def set_background_color(server) do
    ai_tool(
      name: "set_background_color",
      description:
        "set the background color of the chat interface, accepts specified tailwind colors",
      function: fn args -> dispatch_to_liveview(server, "set_background_color", args) end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "color" => %{
            "type" => "string",
            "enum" => [
              "bg-seafoam-950/30",
              "bg-red-950/30",
              "bg-green-950/30",
              "bg-blue-950/30",
              "bg-yellow-950/30",
              "bg-purple-950/30",
              "bg-pink-950/30"
            ]
          }
        },
        "required" => ["color"]
      },
      server: server
    )
  end

  def navigate_to(server) do
    ai_tool(
      name: "navigate_to",
      description: """
      Navigate the user's browser to a page in the application.
      Only use paths that exist in the app:
        "/"          — home page
        "/admin"      — admin panel
        "/chat/:name" — a chat conversation, where :name is the conversation name
      Provide the exact path string including the leading slash.
      """,
      function: fn args -> dispatch_to_liveview(server, "navigate_to", args) end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "The application path to navigate to, e.g. \"/\", \"/admin\", \"/chat/my-chat-id\""
          }
        },
        "required" => ["path"]
      },
      server: server
    )
  end

  # ---------------------------------------------------------------------------
  # Page tools (dynamic, from AiControllable LiveViews)
  # ---------------------------------------------------------------------------

  @doc """
  Builds tool structs for page tools discovered from AiControllable LiveViews.

  Each entry in `pids_and_specs` is `{page_pid, [tool_spec, ...]}` where
  `tool_spec` is a map with `:name`, `:description`, and `:parameters`.

  The generated function sends `{:page_tool_call, name, args, self()}` to
  the page LiveView pid and blocks (inside a Task) waiting for the reply.
  """
  def build_page_tools(server, pids_and_specs) do
    Enum.flat_map(pids_and_specs, fn {page_pid, tool_specs} ->
      Enum.map(tool_specs, fn spec ->
        ai_tool(
          name: spec.name,
          description: spec.description,
          function: fn args ->
            send(page_pid, {:page_tool_call, spec.name, args, self()})

            receive do
              {:page_tool_result, tool_name, result} when tool_name == spec.name ->
                {:ok, result}
            after
              5_000 -> {:ok, "page tool #{spec.name} timed out"}
            end
          end,
          parameters: spec.parameters,
          server: server
        )
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp dispatch_to_liveview(server, tool_name, args) do
    pids = GenServer.call(server, {:session, :get_liveview_pids})

    case pids do
      [] ->
        {:ok, "no browser session active, #{tool_name} skipped"}

      _ ->
        Enum.each(pids, &send(&1, {:liveview_tool_call, tool_name, args}))
        {:ok, "#{tool_name} sent to #{length(pids)} session(s)"}
    end
  end
end
