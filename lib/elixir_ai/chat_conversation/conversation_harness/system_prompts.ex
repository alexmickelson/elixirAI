defmodule ElixirAi.SystemPrompts do
  require Logger

  @dynamic_context_timeout_ms 1_500

  @agent_categories ["user-web"]

  @prompts %{
    "voice" =>
      "You are responding to voice-transcribed input. Keep replies concise and conversational. The user spoke aloud and their message was transcribed, so minor transcription errors may be present.",
    "user-web" => "You are an agent that acts on behalf of a capable user.
When stuck or failing repeatedly, stop guessing and ask the user for clarification or guidance instead of continuing to run unsuccessful commands.
When instructions are vague, ask follow-up questions.

Be brief and terse in your responses.
"
  }

  def for_category(category) do
    case Map.get(@prompts, category) do
      nil ->
        %{prompt: nil, sandbox_error: nil}

      prompt ->
        {dynamic_context, sandbox_error} =
          if category in @agent_categories do
            build_dynamic_context(@dynamic_context_timeout_ms)
          else
            {"", nil}
          end

        %{
          prompt: %{role: :system, content: prompt <> dynamic_context},
          sandbox_error: sandbox_error
        }
    end
  end

  # Fetches a 2-level home directory tree and memory.md from the sandbox
  # at conversation init. Both commands are run in parallel and are bounded so
  # a slow sandbox cannot block ChatRunner startup.
  defp build_dynamic_context(timeout_ms) do
    Logger.info("SystemPrompts: fetching sandbox context for system prompt")

    tree_task =
      Task.async(fn ->
        Logger.info("SystemPrompts: running home directory tree")

        ElixirAi.CommandRunner.run_bash(
          "tree -L 2 /home/sandbox 2>/dev/null || find /home/sandbox -maxdepth 2 | sort"
        )
      end)

    memory_task =
      Task.async(fn ->
        Logger.info("SystemPrompts: reading memory.md")

        ElixirAi.CommandRunner.run_bash(
          "touch /home/sandbox/memory.md && cat /home/sandbox/memory.md"
        )
      end)

    {tree, tree_error} = await_context(tree_task, "home directory tree", timeout_ms)
    {memory, memory_error} = await_context(memory_task, "memory.md", timeout_ms)

    context =
      [
        if(tree != "", do: "\n\n## Home Directory (2 levels deep)\n```\n#{tree}\n```"),
        if(memory != "", do: "\n\n## memory.MD\n#{memory}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    sandbox_error =
      [tree_error, memory_error]
      |> Enum.reject(&is_nil/1)
      |> format_dynamic_context_error()

    {context, sandbox_error}
  end

  defp await_context(task, label, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{stdout: stdout, exit_code: code, duration_ms: ms}}} ->
        Logger.info("SystemPrompts: #{label} complete [exit:#{code} | #{ms}ms]")
        {String.trim(stdout), nil}

      {:ok, {:error, reason}} ->
        message = "#{label}: #{reason}"
        Logger.error("SystemPrompts: #{message}")
        {"", message}

      {:exit, reason} ->
        message = "#{label}: task exited with #{inspect(reason)}"
        Logger.error("SystemPrompts: #{message}")
        {"", message}

      nil ->
        message = "#{label}: timed out after #{timeout_ms}ms"
        Logger.error("SystemPrompts: #{message}")
        {"", message}
    end
  end

  defp format_dynamic_context_error([]), do: nil

  defp format_dynamic_context_error(errors) do
    details =
      errors
      |> Enum.uniq()
      |> Enum.join("; ")

    if String.contains?(details, "Sandbox SSH connection failed") do
      "Sandbox SSH tunnel is unavailable. #{details}. Sandbox-backed tools will not work until the tunnel is restored."
    else
      "Sandbox startup context could not be loaded. #{details}. Sandbox-backed tools may not work until this is fixed."
    end
  end
end
