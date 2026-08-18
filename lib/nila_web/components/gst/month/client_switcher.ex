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
            {period_label(@period)} and {track_label(@selected_track)} will stay selected.
          </p>
        </div>
      </:header>

      <.form
        for={@form}
        id="client-switcher-search-form"
        phx-change="search-client-switcher"
        class="client-switcher-search"
      >
        <.input
          field={@form[:query]}
          type="search"
          placeholder="Search clients"
          aria-label="Search clients"
          autocomplete="off"
          phx-debounce="200"
          phx-mounted={JS.focus()}
        />
      </.form>

      <div id="client-switcher-options" class="client-switcher-options" phx-update="stream">
        <p id="client-switcher-empty" class="text-ink-muted text-ui hidden only:block">
          No clients match this search.
        </p>
        <.link
          :for={{dom_id, option} <- @clients}
          id={dom_id}
          navigate={client_path(option, @period, @selected_track)}
          class="client-switcher-option"
          data-state={if(option.id == @client.id, do: "current", else: "idle")}
          aria-current={if(option.id == @client.id, do: "page", else: nil)}
        >
          <span class="truncate font-medium">{option.name}</span>
          <span :if={option.id == @client.id} class="text-ink-subtle">Current</span>
        </.link>
      </div>
    </.modal>
    """
  end

  defp client_path(client, period, track), do: ~p"/gst/#{client.id}/#{period}?track=#{track}"

  defp track_label(:sales), do: "Sales & GSTR-1"
  defp track_label(:purchases), do: "Purchases & ITC"
  defp track_label(:gstr3b), do: "GSTR-3B"
end
