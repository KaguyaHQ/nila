defmodule NilaWeb.Components.Gst.Month.Workpaper do
  use NilaWeb, :html

  @moduledoc "Section navigation and empty state for the GSTR-3B workpaper."

  attr :links, :list, required: true

  def section_nav(assigns) do
    ~H"""
    <nav
      :if={@links != []}
      aria-label="Workpaper sections"
      class="bg-panel-translucent-surface border-rule rounded-box shadow-moon sticky top-2 z-10 ml-auto w-full overflow-x-auto border p-1 backdrop-blur sm:w-fit"
    >
      <div class="flex min-w-max items-center gap-1">
        <.link
          :for={link <- @links}
          id={"workpaper-section-#{link.id}"}
          href={"##{link.id}"}
          class="hover:bg-interactive hover:text-base-content rounded-field text-ink-muted text-ui px-3 py-1.5 font-semibold"
        >
          {link.label}
        </.link>
      </div>
    </nav>
    """
  end

  attr :track, :atom, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :purchase_present, :boolean, default: false
  attr :show_action, :boolean, default: true

  def empty_state(assigns) do
    assigns = assign(assigns, :copy, empty_copy(assigns.track, assigns.purchase_present))

    ~H"""
    <section
      id={"month-workpaper-empty-#{@track}"}
      class="border-rule p-section rounded-box space-y-block border"
    >
      <div class="space-y-1">
        <h2 class="text-base-content text-h4 font-semibold">{@copy.title}</h2>

        <p class="text-body text-ink-muted">{@copy.body}</p>
      </div>

      <.button
        :if={@show_action and @copy.action}
        id={"month-workpaper-bring-#{@track}"}
        navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}"}
        variant="primary"
        size="sm"
      >
        {@copy.action}
      </.button>
    </section>
    """
  end

  defp empty_copy(:gstr3b, false),
    do: %{
      title: "GSTR-3B",
      body:
        "The purchase and ITC position is not available yet, so Nila cannot assemble GSTR-3B.",
      action: "Bring in purchase bills"
    }

  defp empty_copy(:gstr3b, true),
    do: %{
      title: "GSTR-3B",
      body: "Nila has not assembled a GSTR-3B position for this month.",
      action: nil
    }
end
