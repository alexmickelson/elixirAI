defmodule ElixirAi.AiTools do
  @moduledoc """
  Central registry of all AI tools available to conversations.

  Tools are split into two categories:

  - **Server tools** (`store_thing`, `read_thing`): functions are fully defined
    here and always execute regardless of whether a browser session is open.

  - **LiveView tools** (`set_background_color`, `navigate_to`): functions
    dispatch to the registered LiveView pid. If no browser tab is connected
    the call still succeeds immediately with a descriptive result so the AI
    conversation is never blocked.

  Tool names are stored in the `conversations` table (`allowed_tools` column)
  and act as the gate for which tools are active for a given conversation.
  """

  import ElixirAi.ChatUtils, only: [ai_tool: 1]
  require Logger

  @server_tool_names ["store_thing", "read_thing", "list_conversations", "run"]
  @liveview_tool_names ["set_background_color", "navigate_to"]
  @all_tool_names @server_tool_names ++ @liveview_tool_names

  def server_tool_names, do: @server_tool_names

  def liveview_tool_names, do: @liveview_tool_names

  def all_tool_names, do: @all_tool_names

  def build_server_tools(server, allowed_names) do
    [store_thing(server), read_thing(server), list_conversations(server), run(server)]
    |> Enum.filter(&(&1.name in allowed_names))
  end

  def build_liveview_tools(server, allowed_names) do
    [set_background_color(server), navigate_to(server)]
    |> Enum.filter(&(&1.name in allowed_names))
  end

  @doc "Convenience wrapper — builds all allowed tools (server + liveview)."
  def build(server, allowed_names) do
    build_server_tools(server, allowed_names) ++ build_liveview_tools(server, allowed_names)
  end

  # ---------------------------------------------------------------------------
  # Server tools
  # ---------------------------------------------------------------------------

  def store_thing(server) do
    ai_tool(
      name: "store_thing",
      description: "store a key value pair in memory",
      function: &ElixirAi.ToolTesting.hold_thing/1,
      parameters: ElixirAi.ToolTesting.hold_thing_params(),
      server: server
    )
  end

  def read_thing(server) do
    ai_tool(
      name: "read_thing",
      description: "read a key value pair that was previously stored with store_thing",
      function: &ElixirAi.ToolTesting.get_thing/1,
      parameters: ElixirAi.ToolTesting.get_thing_params(),
      server: server
    )
  end

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
        Execute a command in the sandboxed container. Supports full bash syntax
        including pipes (|), chains (&&, ||), semicolons (;), and redirects.

        One call can be a complete workflow:
          cat log.txt | grep ERROR | wc -l
          curl -sL $URL -o data.csv && head -5 data.csv
          cat config.yaml || echo "not found, using defaults"

        Available tools in the sandbox:
          cat, head, tail, less     — read files
          grep, sed, awk            — filter and transform text
          sort, uniq, wc, tr, cut   — text processing
          find, ls, tree, file      — explore filesystem
          curl, wget                — fetch URLs
          jq                        — parse JSON
          git                       — version control
          bash                      — scripting

        Use --help on any command for detailed usage (e.g. "grep --help").
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

          result =
            case ElixirAi.CommandApproval.classify(command) do
              :auto_allow ->
                ElixirAi.Message.update_approval_decision(tool_call_id, "auto_allowed",
                  topic: topic
                )

                execute_command(command)

              {:needs_approval, reason} ->
                {decision, cmd_result} = request_approval(server, command, reason)

                ElixirAi.Message.update_approval_decision(tool_call_id, Atom.to_string(decision),
                  topic: topic
                )

                cmd_result
            end

          send(server, {:stream, {:tool_response, current_message_id, tool_call_id, result}})
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
