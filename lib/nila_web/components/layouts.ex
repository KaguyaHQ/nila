defmodule NilaWeb.Layouts do
  @moduledoc "Static public-page layouts. Product screens use React."
  use NilaWeb, :html
  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="nila-flash-group" aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
