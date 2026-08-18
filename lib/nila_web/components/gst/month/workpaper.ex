defmodule NilaWeb.Components.Gst.Month.Workpaper do
  use NilaWeb, :html

  @moduledoc "Client-month navigation shared by the three GST workpapers."

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :selected, :atom, required: true
  attr :states, :map, required: true

  def tabs(assigns) do
    ~H"""
    <nav
      id="month-workpapers"
      aria-label="Client-month workpapers"
      class="bg-base-100/40 border-base-300 rounded-box grid overflow-hidden border md:grid-cols-3"
    >
      <.link
        :for={{track, label} <- tracks()}
        id={"month-workpaper-tab-#{track}"}
        patch={~p"/gst/#{@client.id}/#{@period}?track=#{track}"}
        aria-current={@selected == track && "page"}
        data-state={if(@selected == track, do: "selected", else: "idle")}
        class={[
          "border-base-300 nila-workpaper-tab relative min-w-0 border-b px-6 py-4 text-left transition last:border-b-0 md:min-h-20 md:border-r md:border-b-0 md:last:border-r-0",
          @selected != track && "hover:bg-base-100/70"
        ]}
      >
        <span class={[
          "text-ui block truncate font-semibold",
          @selected == track && "text-base-content",
          @selected != track && "text-ink-muted"
        ]}>
          {label}
        </span>
        <span class="mt-related text-ink-muted text-ui flex items-center gap-2 font-medium">
          <span class={["size-2 shrink-0 rounded-full", state_dot(@states[track].variant)]}></span>
          <span class="truncate">{@states[track].label}</span>
        </span>
      </.link>
    </nav>
    """
  end

  attr :links, :list, required: true

  def section_nav(assigns) do
    ~H"""
    <nav
      :if={@links != []}
      aria-label="Workpaper sections"
      class="bg-base-100/95 border-base-300 rounded-box shadow-moon sticky top-2 z-10 ml-auto w-full overflow-x-auto border p-1 backdrop-blur sm:w-fit"
    >
      <div class="flex min-w-max items-center gap-1">
        <.link
          :for={link <- @links}
          id={"workpaper-section-#{link.id}"}
          href={"##{link.id}"}
          class="hover:bg-base-200 hover:text-base-content rounded-field text-ink-muted text-ui px-3 py-1.5 font-semibold"
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
      class="border-base-300 p-section rounded-box space-y-block border"
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

  defp tracks do
    [
      {:sales, "Sales & GSTR-1"},
      {:purchases, "Purchases & ITC"},
      {:gstr3b, "GSTR-3B"}
    ]
  end

  defp state_dot("success"), do: "bg-success"
  defp state_dot("warning"), do: "bg-warning"
  defp state_dot("error"), do: "bg-error"
  defp state_dot("info"), do: "bg-info"
  defp state_dot(_variant), do: "bg-neutral/55"

  defp empty_copy(:sales, _purchase_present),
    do: %{
      title: "Sales & GSTR-1",
      body: "No sales documents are in for this month.",
      action: "Bring in sales bills"
    }

  defp empty_copy(:purchases, _purchase_present),
    do: %{
      title: "Purchases & ITC",
      body: "No purchase documents are in for this month.",
      action: "Bring in purchase bills"
    }

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
