defmodule ElixirAiWeb.UserMessage do
  use Phoenix.Component

  defp max_width_class, do: "max-w-full xl:max-w-300"

  attr :content, :string, required: true

  def user_message(assigns) do
    ~H"""
    <div class="mb-2 text-sm text-right">
      <div class={"ml-auto w-fit px-3 py-2 rounded-lg  bg-seafoam-950 text-seafoam-50 #{max_width_class()} text-left"}>
        {@content}
      </div>
    </div>
    """
  end
end
