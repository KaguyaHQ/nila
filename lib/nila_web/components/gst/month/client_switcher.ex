defmodule NilaWeb.Components.Gst.Month.ClientSwitcher do
  @moduledoc "The period-preserving client switcher for the GST month workbench."
  use NilaWeb, :html

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :open?, :boolean, required: true

  def trigger(assigns) do
    ~H"""
    <button
      type="button"
      id="open-client-switcher"
      class="client-switcher-trigger"
      phx-click="open-client-switcher"
      aria-haspopup="dialog"
      aria-controls="client-switcher"
      aria-expanded={to_string(@open?)}
    >
      <h1 class="font-display text-base-content text-h4 font-normal">{@client.name}</h1>
      <.icon name="hero-chevron-down" class="client-switcher-chevron size-4" />
      <span class="text-ink-subtle text-ui font-medium">
        {period_label(@period)}
      </span>
    </button>
    """
  end

  attr :open?, :boolean, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :selected_track, :atom, required: true
  attr :form, :map, required: true
  attr :clients, :any, required: true

  def drawer(assigns) do
    ~H"""
    <.modal
      :if={@open?}
      id="client-switcher"
      title="Switch client"
      on_close="close-client-switcher"
      variant="sheet"
      side="right"
      return_focus="#open-client-switcher"
    >
      <:header :let={title_id}>
        <div class="space-y-related">
          <h2 id={title_id} class="font-display text-base-content text-h4 font-normal">
            Switch client
          </h2>
          <p class="text-ink-muted text-ui">
            {period_label(@period)} · {track_label(@selected_track)}
          </p>
        </div>
      </:header>

      <div
        id="client-switcher-navigation"
        phx-hook="SelectableList"
        data-loop="true"
        data-filter-value={@form[:query].value || ""}
      >
        <.form
          for={@form}
          id="client-switcher-search-form"
          phx-change="search-client-switcher"
          phx-submit="select-client-switcher"
          class="client-switcher-search"
        >
          <.input
            field={@form[:query]}
            type="search"
            placeholder="Search clients"
            aria-label="Search clients"
            aria-controls="client-switcher-options"
            role="combobox"
            aria-expanded="true"
            aria-autocomplete="list"
            autocomplete="off"
            phx-debounce="200"
            phx-mounted={JS.focus()}
            data-selectable-input
          />
        </.form>

        <.selectable_listbox
          id="client-switcher-options"
          phx-update="stream"
          label="Clients"
        >
          <p id="client-switcher-empty" class="text-ink-muted text-ui hidden only:block">
            No clients match this search.
          </p>
          <.selectable_option
            :for={{dom_id, option} <- @clients}
            id={dom_id}
            navigate={
              if(option.id != @client.id,
                do: client_path(option, @period, @selected_track)
              )
            }
            phx-click={if(option.id == @client.id, do: "close-client-switcher")}
            selected={option.id == @client.id}
            aria_current={if(option.id == @client.id, do: "page", else: nil)}
          >
            {option.name}
            <:meta :if={option.id == @client.id}>Current</:meta>
          </.selectable_option>
        </.selectable_listbox>
      </div>
    </.modal>
    """
  end

  defp client_path(client, period, track), do: ~p"/gst/#{client.id}/#{period}?track=#{track}"

  defp track_label(:sales), do: "Sales & GSTR-1"
  defp track_label(:purchases), do: "Purchases & ITC"
  defp track_label(:gstr3b), do: "GSTR-3B"
end
