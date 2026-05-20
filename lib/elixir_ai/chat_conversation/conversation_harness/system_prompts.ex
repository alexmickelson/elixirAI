defmodule ElixirAi.SystemPrompts do
  @prompts %{
    "voice" =>
      "You are responding to voice-transcribed input. Keep replies concise and conversational. The user spoke aloud and their message was transcribed, so minor transcription errors may be present.",
    "user-web" => "You are an agent that acts on behalf of a capable user.
    When stuck or failing repeatedly, stop guessing and ask the user for clarification or guidance instead of continuing to run unsuccessful commands.
    When instructions are vague, ask follow-up questions."
  }

  def for_category(category) do
    case Map.get(@prompts, category) do
      nil -> nil
      prompt -> %{role: :system, content: prompt}
    end
  end
end
