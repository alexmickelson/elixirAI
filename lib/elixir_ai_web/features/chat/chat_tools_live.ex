defmodule ElixirAiWeb.ChatToolsLive do
  use ElixirAiWeb, :live_component
  alias ElixirAi.{AiTools, ChatRunner}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:all_tools, fn -> AiTools.all_tool_names() end)
     |> assign_new(:allowed_tools, fn ->
       case ChatRunner.get_conversation(assigns.conversation_name) do
         %{allowed_tools: tools} -> tools
         _ -> AiTools.all_tool_names()
       end
     end)}
  end

  def render(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_tools_popup"
        phx-target={@myself}
        class="px-3 py-2 rounded text-sm border border-seafoam-900/40 bg-seafoam-950/20 text-seafoam-300 hover:border-seafoam-700 hover:bg-seafoam-950/40 transition-colors flex items-center gap-1"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M11.42 15.17l-5.1 5.1a2.12 2.12 0 01-3-3l5.1-5.1m0 0L3.07 7.83a1.5 1.5 0 010-2.12l1.42-1.42a1.5 1.5 0 012.12 0l4.24 4.24m0 0l2.12-2.12m-2.12 2.12l5.1 5.1a2.12 2.12 0 003-3l-5.1-5.1m0 0l2.12-2.12a1.5 1.5 0 012.12 0l1.42 1.42a1.5 1.5 0 010 2.12L16.93 12"
          />
        </svg>
        Tools
      </button>

      <%= if @open do %>
        <div class="absolute bottom-full mb-2 right-0 w-64 rounded-lg border border-seafoam-900/40 bg-seafoam-950 shadow-lg z-50">
          <div class="px-3 py-2 border-b border-seafoam-900/40">
            <span class="text-sm font-medium text-seafoam-300">Toggle Tools</span>
          </div>
          <ul class="py-1">
            <%= for tool <- @all_tools do %>
              <li class="px-3 py-1.5">
                <button
                  type="button"
                  phx-click="toggle_tool"
                  phx-value-tool={tool}
                  phx-target={@myself}
                  class="flex items-center justify-between w-full cursor-pointer group"
                >
                  <span class="text-sm text-seafoam-400 group-hover:text-seafoam-200 transition-colors">
                    {tool}
                  </span>
                  <span class={[
                    "relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
                    if(tool in @allowed_tools,
                      do: "bg-seafoam-500",
                      else: "bg-seafoam-900/60"
                    )
                  ]}>
                    <span class={[
                      "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow ring-0 transition-transform duration-200 ease-in-out",
                      if(tool in @allowed_tools,
                        do: "translate-x-4",
                        else: "translate-x-0"
                      )
                    ]} />
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_event("toggle_tools_popup", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open)}
  end

  def handle_event("toggle_tool", %{"tool" => tool_name}, socket) do
    allowed = socket.assigns.allowed_tools

    new_allowed =
      if tool_name in allowed do
        List.delete(allowed, tool_name)
      else
        allowed ++ [tool_name]
      end

    ChatRunner.set_allowed_tools(socket.assigns.conversation_name, new_allowed)
    {:noreply, assign(socket, allowed_tools: new_allowed)}
  end
end
