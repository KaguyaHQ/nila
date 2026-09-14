defmodule NilaWeb.ClientSwitcherComponent do
  use NilaWeb, :live_component

  alias Nila.Clients

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:palette?, false)
     |> assign(:show_trigger, true)
     |> assign(:sales_period, nil)
     |> assign(:form, search_form())
     |> stream_configure(:clients, dom_id: &"shell-client-switcher-client-#{&1.id}")
     |> stream(:clients, [])
     |> stream(:destinations, [])}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:active_client, assigns[:active_client] || assigns.current_scope.current_client)}
  end

  @impl true
  def handle_event("open", params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
     |> assign(:palette?, params["palette"] == "true")
     |> assign(:form, search_form())
     |> refresh_clients("")}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open?, false)}

  def handle_event("search", %{"client_switcher" => params}, socket) do
    query = Map.get(params, "query", "")

    {:noreply,
     socket
     |> assign(:form, search_form(query))
     |> refresh_clients(query)}
  end

  defp refresh_clients(socket, query) do
    clients =
      socket.assigns.current_scope.current_org.id
      |> Clients.list_clients()
      |> filter_clients(query)

    destinations =
      if socket.assigns.palette? do
        NilaWeb.GoTo.destinations(
          socket.assigns.active_client,
          socket.assigns.current_path,
          socket.assigns.sales_period
        )
      else
        []
      end

    socket
    |> stream(:clients, clients, reset: true)
    |> stream(:destinations, destinations, reset: true)
    |> assign(:client_count, length(clients))
    |> assign(:empty?, clients == [] && destinations == [])
  end

  defp filter_clients(clients, query) when query in [nil, ""], do: clients

  defp filter_clients(clients, query) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(
      clients,
      &String.contains?(String.downcase(&1.name <> " " <> (&1.gstin || "")), query)
    )
  end

  defp search_form(query \\ ""), do: to_form(%{"query" => query}, as: :client_switcher)

  defp switch_path(client, current_path) do
    return_to = destination_for(current_path, client.id)
    ~p"/clients/#{client.id}/select?return_to=#{return_to}"
  end

  defp destination_for(path, client_id) when is_binary(path) do
    uri = URI.parse(path)

    cond do
      uri.path == "/gst/upload" ->
        query = URI.decode_query(uri.query || "") |> Map.put("client_id", to_string(client_id))
        "/gst/upload?" <> URI.encode_query(query)

      Regex.match?(~r|^/gst/\d+/\d{4}-\d{2}/sales/invoices/|, uri.path) ->
        [_, period] = Regex.run(~r|^/gst/\d+/(\d{4}-\d{2})/|, uri.path)
        "/gst/#{client_id}/#{period}/sales"

      Regex.match?(~r|^/gst/\d+/[^/]+|, path) ->
        Regex.replace(~r|^/gst/\d+|, path, "/gst/#{client_id}")

      String.starts_with?(path, "/sales-bills/") ->
        "/sales-bills"

      String.starts_with?(path, "/banking/") ->
        "/banking"

      true ->
        path
    end
  end

  defp destination_for(_path, _client_id), do: "/sales-bills"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="shell-client-switcher"
      phx-hook=".ClientSwitcherShortcut"
      phx-target={@myself}
      class="mt-block min-w-0"
    >
      <button
        :if={@show_trigger}
        type="button"
        id="shell-client-switcher-trigger"
        phx-click="open"
        phx-target={@myself}
        class="focus-visible:outline-focus hover:bg-interactive rounded-field text-base-content text-ui flex h-10 w-full items-center gap-3 px-2 text-left transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0 focus-visible:outline-2 focus-visible:outline-offset-2"
        aria-haspopup="dialog"
        aria-controls="shell-client-switcher-sheet"
        aria-expanded={to_string(@open?)}
        title={"#{@active_client.name} — Switch client"}
      >
        <span class="bg-interactive text-ink-muted grid size-8 shrink-0 place-items-center rounded-full">
          <.icon name="hero-building-office-2" class="size-4" />
        </span>

        <span class="text-base-content min-w-0 flex-1 truncate font-semibold group-data-[rail-collapsed=true]/app:hidden">
          {@active_client.name}
        </span>

        <.icon
          name="hero-chevron-up-down"
          class="text-ink-subtle size-4 shrink-0 group-data-[rail-collapsed=true]/app:hidden"
        />
      </button>

      <.modal
        :if={@open?}
        id="shell-client-switcher-sheet"
        title={if @palette?, do: "Go to…", else: "Switch client"}
        on_close="close"
        target={@myself}
        variant={if @palette?, do: "modal", else: "sheet"}
        side="right"
        return_focus={if !@palette?, do: "#shell-client-switcher-trigger"}
      >
        <div
          id="shell-client-switcher-navigation"
          phx-hook={if @palette?, do: "CommandPalette", else: "SelectableList"}
          data-loop="true"
          data-filter-value={if !@palette?, do: @form[:query].value || ""}
          data-current-period={NilaWeb.GoTo.period(@current_path, @sales_period)}
        >
          <.form
            for={@form}
            id="shell-client-switcher-search-form"
            phx-change={if !@palette?, do: "search"}
            phx-submit={if !@palette?, do: "search"}
            phx-target={@myself}
            class="client-switcher-search"
          >
            <.input
              field={@form[:query]}
              type="search"
              placeholder={
                if @palette?, do: "Search pages, clients or a month…", else: "Search clients"
              }
              aria-label={if @palette?, do: "Search destinations", else: "Search clients"}
              aria-controls="shell-client-switcher-options"
              role="combobox"
              aria-expanded="true"
              aria-autocomplete="list"
              autocomplete="off"
              phx-debounce={if !@palette?, do: "200"}
              phx-mounted={JS.focus()}
              data-selectable-input
            />
          </.form>

          <div class="max-h-96 overflow-y-auto">
            <.selectable_listbox
              id="shell-client-switcher-options"
              label={if @palette?, do: "Destinations", else: "Clients"}
            >
              <div :if={@palette?} id="go-to-destinations" phx-update="stream">
                <div
                  :for={{dom_id, destination} <- @streams.destinations}
                  id={dom_id}
                  role="presentation"
                >
                  <p
                    :if={destination.heading}
                    data-command-heading={destination.group}
                    class="text-ink-muted text-label px-3 pt-4 pb-2 font-medium"
                    role="presentation"
                  >
                    {destination.heading}
                  </p>
                  <.selectable_option
                    id={"#{dom_id}-link"}
                    navigate={destination.path}
                    data-command-group={destination.group}
                    data-command-search={destination.label <> " " <> destination.keywords}
                    data-command-period={destination.period}
                    data-command-path={destination.path}
                    data-command-suggested={to_string(destination.suggested)}
                    hidden={destination.period != nil && !destination.suggested}
                  >
                    <span class="block" data-command-label>{destination.label}</span>
                    <span
                      :if={destination.context}
                      class="text-ink-muted text-label block font-normal"
                    >
                      {destination.context}
                    </span>
                  </.selectable_option>
                </div>
              </div>
              <p
                :if={@palette? && @client_count > 0}
                data-command-heading="Clients"
                class="text-ink-muted text-label px-3 pt-4 pb-2 font-medium"
                role="presentation"
              >
                Clients
              </p>
              <p
                :if={@palette? || @empty?}
                hidden={not @empty?}
                data-command-empty
                id="shell-client-switcher-empty"
                class="text-ink-muted text-ui px-3 py-4"
              >
                {if @palette?,
                  do: "No matching pages, clients or periods.",
                  else: "No clients match this search."}
              </p>
              <div id="shell-client-switcher-clients" phx-update="stream">
                <.selectable_option
                  :for={{dom_id, client} <- @streams.clients}
                  id={dom_id}
                  data-command-group="Clients"
                  data-command-search={client.name <> " " <> (client.gstin || "")}
                  href={
                    if(client.id != @active_client.id,
                      do:
                        switch_path(
                          client,
                          if(@palette?,
                            do: NilaWeb.GoTo.client_path(@current_path, @sales_period, client.id),
                            else: @current_path
                          )
                        )
                    )
                  }
                  method={if(client.id != @active_client.id, do: "post")}
                  phx-click={if(client.id == @active_client.id, do: "close")}
                  phx-target={if(client.id == @active_client.id, do: @myself)}
                  selected={client.id == @active_client.id}
                  aria_current={if(client.id == @active_client.id, do: "page")}
                >
                  <span class="block text-left">{client.name}</span>
                  <span :if={@palette?} class="text-ink-muted text-label block text-left font-normal">
                    <span :if={client.gstin}>{client.gstin} · </span> {NilaWeb.GoTo.period_label(
                      NilaWeb.GoTo.period(@current_path, @sales_period)
                    )}
                  </span>
                  <:meta :if={client.id == @active_client.id}>Current</:meta>
                </.selectable_option>
              </div>
            </.selectable_listbox>
          </div>
        </div>
      </.modal>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ClientSwitcherShortcut">
        export default {
          mounted() {
            this.onKey = event => {
              if (event.defaultPrevented || event.repeat || event.isComposing || event.altKey || event.shiftKey) return
              if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "k") return
              if (localStorage.getItem("nila-shortcuts-enabled") === "false") return
              if (document.querySelector(":popover-open")) return

              const sheet = this.el.querySelector("#shell-client-switcher-sheet")
              const dialogs = [...document.querySelectorAll('dialog[open], [role="dialog"]')]
                .filter(dialog => dialog.getClientRects().length)
              if (dialogs.some(dialog => dialog !== sheet)) return

              if (sheet) {
                const search = sheet.querySelector("[data-selectable-input]")
                if (search) {
                  event.preventDefault()
                  search.focus({preventScroll: true})
                }
                return
              }

              if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="combobox"], [role="listbox"], [role="tablist"], [role="slider"]')) return
              event.preventDefault()
              this.pushEventTo(this.el, "open", {palette: "true"})
            }
            window.addEventListener("keydown", this.onKey)
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey)
          }
        }
      </script>
    </div>
    """
  end
end
