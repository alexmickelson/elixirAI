defmodule ElixirAi.SystemPrompts do
  require Logger

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
        nil

      prompt ->
        content =
          if category in @agent_categories do
            prompt <> build_dynamic_context()
          else
            prompt
          end

        %{role: :system, content: content}
    end
  end

  # Fetches a 2-level home directory tree and memory.md from the sandbox
  # at conversation init. Both commands are run in parallel.
  defp build_dynamic_context do
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

    tree = await_context(tree_task, "home directory tree")
    memory = await_context(memory_task, "memory.md")

    [
      if(tree != "", do: "\n\n## Home Directory (2 levels deep)\n```\n#{tree}\n```"),
      if(memory != "", do: "\n\n## memory.MD\n#{memory}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp await_context(task, label) do
    case Task.await(task, 15_000) do
      {:ok, %{stdout: stdout, exit_code: code, duration_ms: ms}} ->
        Logger.info("SystemPrompts: #{label} complete [exit:#{code} | #{ms}ms]")
        String.trim(stdout)

      {:error, reason} ->
        Logger.warning("SystemPrompts: #{label} failed — #{inspect(reason)}")
        ""
    end
  end
end
