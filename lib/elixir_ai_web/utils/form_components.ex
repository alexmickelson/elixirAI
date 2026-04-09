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
      <label for={@name} class="block text-sm text-seafoam-300 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@name}
        value={@value}
        autocomplete={@autocomplete}
        class="w-full rounded px-3 py-2 text-sm bg-seafoam-950/20 border border-seafoam-900/40 text-seafoam-100 focus:outline-none focus:ring-1 focus:ring-seafoam-700"
        {@rest}
      />
    </div>
    """
  end

  @doc """
  Renders a toggle switch button.

  ## Examples

      <.toggle id="my-toggle" checked={@enabled} label="Enable" phx-click="toggle" phx-target={@myself} />
  """
  attr :id, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <button id={@id} type="button" {@rest} class="flex items-center gap-1.5 cursor-pointer group">
      <span class={[
        "relative inline-flex h-5 w-9 shrink-0 rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out",
        if(@checked, do: "bg-seafoam-500", else: "bg-seafoam-900/60")
      ]}>
        <span class={[
          "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow ring-0 transition-transform duration-200 ease-in-out",
          if(@checked, do: "translate-x-4", else: "translate-x-0")
        ]} />
      </span>
      <span class="text-xs text-seafoam-500 group-hover:text-seafoam-300 transition-colors capitalize">
        {@label}
      </span>
    </button>
    """
  end

  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div class="w-full max-w-sm rounded-lg border border-seafoam-900/40 bg-seafoam-950 p-6 shadow-xl">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
