defmodule ElixirAi.ToolTesting do
  use GenServer

  def hold_thing(thing) do
    GenServer.cast(__MODULE__, {:hold_thing, thing})
  end

  def hold_thing_params do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "value" => %{"type" => "string"}
      },
      "required" => ["name", "value"]
    }
  end

  def get_thing(_) do
    GenServer.call(__MODULE__, :get_thing)
  end

  def get_thing_params do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  def store_thing_params do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "value" => %{"type" => "string"}
      },
      "required" => ["name", "value"]
    }
  end

  def set_background_color(%{"color" => color}) do
    Phoenix.PubSub.broadcast(ElixirAi.PubSub, "ai_chat", {:set_background_color, color})
  end

  def set_background_color_params do
    valid_tailwind_colors = ElixirAiWeb.ChatLive.valid_background_colors()

    %{
      "type" => "object",
      "properties" => %{
        "color" => %{
          "type" => "string",
          "enum" => valid_tailwind_colors
        }
      },
      "required" => ["color"]
    }
  end

  def read_thing_definition(name) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => "read key value pair that was previously stored with store_thing"
      }
    }
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(args) do
    {:ok, args}
  end

  def handle_cast({:hold_thing, thing}, _state) do
    {:noreply, thing}
  end

  def handle_call(:get_thing, _from, state) do
    {:reply, state, state}
  end
end
