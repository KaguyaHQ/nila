defmodule NilaWeb.ClientSwitcherComponent do
  use NilaWeb, :live_component

  alias Nila.Clients

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open?, false)
     |> assign(:form, search_form())
     |> stream_configure(:clients, dom_id: &"shell-client-switcher-client-#{&1.id}")
     |> stream(:clients, [])}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:active_client, assigns[:active_client] || assigns.current_scope.current_client)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply,
     socket
     |> assign(:open?, true)
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

    stream(socket, :clients, clients, reset: true)
  end

  defp filter_clients(clients, query) when query in [nil, ""], do: clients

  defp filter_clients(clients, query) do
    query = query |> String.trim() |> String.downcase()
    Enum.filter(clients, &String.contains?(String.downcase(&1.name), query))
  end

  defp search_form(query \\ ""), do: to_form(%{"query" => query}, as: :client_switcher)

  defp switch_path(client, current_path) do
    return_to = destination_for(current_path, client.id)
    ~p"/clients/#{client.id}/select?return_to=#{return_to}"
  end

  defp destination_for(path, client_id) when is_binary(path) do
    cond do
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
    <div id="shell-client-switcher" class="mt-block min-w-0">
      <button
        type="button"
        id="shell-client-switcher-trigger"
        phx-click="open"
        phx-target={@myself}
        class="focus-visible:outline-base-100/40 hover:bg-base-100/10 rounded-field text-base-100/80 text-ui flex h-10 w-full items-center gap-3 px-2 text-left transition group-data-[rail-collapsed=true]/app:justify-center group-data-[rail-collapsed=true]/app:px-0 focus-visible:outline-2 focus-visible:outline-offset-2"
        aria-haspopup="dialog"
        aria-controls="shell-client-switcher-sheet"
        aria-expanded={to_string(@open?)}
        title={@active_client.name}
      >
        <span class="bg-base-100/10 text-base-100/70 grid size-8 shrink-0 place-items-center rounded-full">
          <.icon name="hero-building-office-2" class="size-4" />
        </span>
        <span class="text-base-100 min-w-0 flex-1 truncate font-semibold group-data-[rail-collapsed=true]/app:hidden">
          {@active_client.name}
        </span>
        <.icon
          name="hero-chevron-up-down"
          class="text-base-100/45 size-4 shrink-0 group-data-[rail-collapsed=true]/app:hidden"
        />
      </button>

      <.modal
        :if={@open?}
        id="shell-client-switcher-sheet"
        title="Switch client"
        on_close="close"
        target={@myself}
        variant="sheet"
        side="right"
        return_focus="#shell-client-switcher-trigger"
      >
        <div
          id="shell-client-switcher-navigation"
          phx-hook="SelectableList"
          data-loop="true"
          data-filter-value={@form[:query].value || ""}
        >
          <.form
            for={@form}
            id="shell-client-switcher-search-form"
            phx-change="search"
            phx-target={@myself}
            class="client-switcher-search"
          >
            <.input
              field={@form[:query]}
              type="search"
              placeholder="Search clients"
              aria-label="Search clients"
              aria-controls="shell-client-switcher-options"
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
            id="shell-client-switcher-options"
            phx-update="stream"
            label="Clients"
          >
            <p id="shell-client-switcher-empty" class="text-ink-muted text-ui hidden only:block">
              No clients match this search.
            </p>
            <.selectable_option
              :for={{dom_id, client} <- @streams.clients}
              id={dom_id}
              href={
                if(client.id != @active_client.id,
                  do: switch_path(client, @current_path)
                )
              }
              method={if(client.id != @active_client.id, do: "post")}
              phx-click={if(client.id == @active_client.id, do: "close")}
              phx-target={if(client.id == @active_client.id, do: @myself)}
              selected={client.id == @active_client.id}
              aria_current={if(client.id == @active_client.id, do: "page")}
            >
              {client.name}
              <:meta :if={client.id == @active_client.id}>Current</:meta>
            </.selectable_option>
          </.selectable_listbox>
        </div>
      </.modal>
    </div>
    """
  end
end
