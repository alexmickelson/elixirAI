defmodule ElixirAi.SystemPrompts do
  @prompts %{
    "voice" =>
      "You are responding to voice-transcribed input. Keep replies concise and conversational. The user spoke aloud and their message was transcribed, so minor transcription errors may be present.",
    "user-web" => nil
  }

  def for_category(category) do
    case Map.get(@prompts, category) do
      nil -> nil
      prompt -> %{role: :system, content: prompt}
    end
  end
end
