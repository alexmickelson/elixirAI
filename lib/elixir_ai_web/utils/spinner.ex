defmodule ElixirAiWeb.Spinner do
  use Phoenix.Component

  attr :class, :string, default: nil

  def spinner(assigns) do
    ~H"""
    <span class={["loader", @class]}></span>
    """
  end
end
