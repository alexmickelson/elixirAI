defmodule ElixirAiWeb.ChatProviderDisplay do
  use Phoenix.Component

  attr :provider, :any, default: nil

  def chat_provider_display(%{provider: nil} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 text-xs text-cyan-900 italic">
      No provider set
    </div>
    """
  end

  def chat_provider_display(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-xs min-w-0">
      <div class="flex items-center gap-1.5 px-2 py-1 rounded bg-cyan-950/50 border border-cyan-900/40 min-w-0">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          class="w-3 h-3 shrink-0 text-cyan-600"
        >
          <path d="M10 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 8a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM1.49 15.326a.78.78 0 0 1-.358-.442 3 3 0 0 1 4.308-3.516 6.484 6.484 0 0 0-1.905 3.959c-.023.222-.014.442.025.654a4.97 4.97 0 0 1-2.07-.655ZM16.44 15.98a4.97 4.97 0 0 0 2.07-.654.78.78 0 0 0 .357-.442 3 3 0 0 0-4.308-3.516 6.484 6.484 0 0 1 1.907 3.96 2.32 2.32 0 0 1-.026.654ZM18 8a2 2 0 1 1-4 0 2 2 0 0 1 4 0ZM5.304 16.19a.844.844 0 0 1-.277-.71 5 5 0 0 1 9.947 0 .843.843 0 0 1-.277.71A6.975 6.975 0 0 1 10 18a6.974 6.974 0 0 1-4.696-1.81Z" />
        </svg>
        <span class="text-cyan-400 font-medium truncate">{@provider.name}</span>
        <span class="text-cyan-800">·</span>
        <span class="text-cyan-600 truncate">{@provider.model_name}</span>
      </div>
    </div>
    """
  end
end
