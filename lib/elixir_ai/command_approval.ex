defmodule ElixirAi.CommandApproval do
  @moduledoc """
  Classifies sandbox commands as auto-allowed or requiring human approval
  by asking an AI with structured output.
  """

  alias ElixirAi.{AiProvider, AiUtils.StructuredResponse}
  require Logger

  @schema %{
    "type" => "object",
    "properties" => %{
      "needs_approval" => %{"type" => "boolean"},
      "justification" => %{
        "type" => "string",
        "description" => "One sentence explaining why this command is or is not approved."
      }
    },
    "required" => ["needs_approval", "justification"],
    "additionalProperties" => false
  }

  @system_prompt %{
    role: :system,
    content: """
    You are a security classifier for shell commands executed in a sandboxed container.

    Auto-allow read-only operations: viewing files, listing directories, searching,
    filtering, text processing, fetching URLs, and read-only git operations.

    Require approval for: writes to files, deletes, installs, system configuration
    changes, git commits/pushes/resets, and anything that modifies persistent state.

    When in doubt, require approval.
    """
  }

  @doc """
  Classify a shell command. Returns `:auto_allow` or `{:needs_approval, reason}`.
  Falls back to requiring approval if the AI cannot be reached.
  """
  def classify(command) do
    messages = [%{role: :user, content: "Command: #{command}"}]

    with {:ok, provider} <- AiProvider.get_shell_classifier(),
         {:ok, %{"needs_approval" => needs_approval, "justification" => justification}} <-
           StructuredResponse.request(messages, provider, "command_approval", @schema,
             system_prompt: @system_prompt
           ) do
      if needs_approval,
        do: {:needs_approval, justification},
        else: {:auto_allow, justification}
    else
      error ->
        Logger.warning("CommandApproval AI check failed: #{inspect(error)}, requiring approval")
        {:needs_approval, "approval check unavailable"}
    end
  end
end
