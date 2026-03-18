defmodule ElixirAiWeb.FormComponents do
  use Phoenix.Component

  @doc """
  Renders a styled input field with label.

  ## Examples

      <.input type="text" name="email" value={@email} label="Email" />
      <.input type="password" name="password" label="Password" />
  """
  attr :type, :string, default: "text"
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :label, :string, required: true
  attr :autocomplete, :string, default: "off"
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div>
      <label for={@name} class="block text-sm text-cyan-300 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@name}
        value={@value}
        autocomplete={@autocomplete}
        class="w-full rounded px-3 py-2 text-sm bg-cyan-950/20 border border-cyan-900/40 text-cyan-100 focus:outline-none focus:ring-1 focus:ring-cyan-700"
        {@rest}
      />
    </div>
    """
  end

  @doc """
  Renders a centered overlay modal. Pass content via the `:inner_block` slot.

  ## Examples

      <.modal>
        <p>Are you sure?</p>
      </.modal>
  """
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div class="w-full max-w-sm rounded-lg border border-cyan-900/40 bg-cyan-950 p-6 shadow-xl">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
