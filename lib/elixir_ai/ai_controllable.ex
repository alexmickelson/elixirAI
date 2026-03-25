defmodule ElixirAi.AiControllable do
  @moduledoc """
  Behaviour + macro for LiveViews that expose AI-controllable tools.

  Any LiveView that `use`s this module must implement:

    - `ai_tools/0`  — returns a list of tool spec maps
    - `handle_ai_tool_call(tool_name, args, socket)` — handles a dispatched tool call,
      returns `{result_string, socket}`.

  The macro injects:

    - A `handle_info` clause that dispatches `{:page_tool_call, tool_name, args, reply_to}`
      messages to the callback and sends the result back to the caller.
    - An `on_mount` hook registration that joins the `:pg` group keyed by
      `voice_session_id` so VoiceLive can discover sibling page LiveViews.

  ## Usage

      defmodule MyAppWeb.SomeLive do
        use MyAppWeb, :live_view
        use ElixirAi.AiControllable

        @impl ElixirAi.AiControllable
        def ai_tools do
          [
            %{
              name: "do_something",
              description: "Does something useful",
              parameters: %{
                "type" => "object",
                "properties" => %{"value" => %{"type" => "string"}},
                "required" => ["value"]
              }
            }
          ]
        end

        @impl ElixirAi.AiControllable
        def handle_ai_tool_call("do_something", %{"value" => val}, socket) do
          {"done: \#{val}", assign(socket, value: val)}
        end
      end
  """

  @callback ai_tools() :: [map()]
  @callback handle_ai_tool_call(tool_name :: String.t(), args :: map(), socket :: term()) ::
              {String.t(), term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour ElixirAi.AiControllable

      on_mount ElixirAi.AiControllable.Hook

      def handle_info({:page_tool_call, tool_name, args, reply_to}, socket) do
        {result, socket} = handle_ai_tool_call(tool_name, args, socket)
        send(reply_to, {:page_tool_result, tool_name, result})
        {:noreply, socket}
      end

      def handle_info({:get_ai_tools, reply_to}, socket) do
        send(reply_to, {:ai_tools_response, self(), ai_tools()})
        {:noreply, socket}
      end
    end
  end
end
