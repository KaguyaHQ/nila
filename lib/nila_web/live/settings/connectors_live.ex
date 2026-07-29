defmodule NilaWeb.Settings.ConnectorsLive do
  use NilaWeb, :live_view

  alias Nila.Integrations
  alias Nila.Integrations.{Connection, GmailSyncWorker}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Connector settings")
     |> assign(:settings_section, :connectors)
     |> assign(:gmail_form, to_form(%{}, as: :connection))
     |> load_connector_state()}
  end

  @impl true
  def handle_event("update_connection", %{"id" => id, "connection" => params}, socket) do
    with {:ok, connection} <- fetch_current_org_connection(socket, id),
         {:ok, _connection} <-
           Integrations.update_connection(connection, connection_params(params)) do
      {:noreply,
       socket
       |> put_flash(:info, "Connection updated.")
       |> load_connector_state()}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not update connection.")}
    end
  end

  @impl true
  def handle_event("disconnect", %{"id" => id}, socket) do
    with {:ok, connection} <- fetch_current_org_connection(socket, id),
         {:ok, _connection} <- Integrations.disconnect(connection) do
      {:noreply,
       socket
       |> put_flash(:info, "Connection disconnected.")
       |> load_connector_state()}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not disconnect connection.")}
    end
  end

  @impl true
  def handle_event("reconnect", %{"id" => id}, socket) do
    with {:ok, connection} <- fetch_current_org_connection(socket, id),
         {:ok, _connection} <- Integrations.reconnect(connection) do
      {:noreply,
       socket
       |> put_flash(:info, "Connection marked active. Re-run OAuth if credentials are stale.")
       |> load_connector_state()}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Could not reconnect connection.")}
    end
  end

  @impl true
  def handle_event("sync_now", %{"id" => id}, socket) do
    with {:ok, %{provider: "gmail"} = connection} <- fetch_current_org_connection(socket, id),
         {:ok, _job} <- %{connection_id: connection.id} |> GmailSyncWorker.new() |> Oban.insert() do
      {:noreply, put_flash(socket, :info, "Mailbox sync queued.")}
    else
      {:ok, _connection} ->
        {:noreply, put_flash(socket, :error, "Manual sync is not available for this connector.")}

      _error ->
        {:noreply, put_flash(socket, :error, "Could not queue sync.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.settings
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div id="settings-connectors" class="space-y-6">
        <.settings_header title="Connectors">
          Connect the inboxes and channels documents arrive on. Labels show up in
          operational views so the team can tell the firm's intake channels apart.
        </.settings_header>

        <.settings_panel>
          <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h3 class="text-base-content text-body font-semibold">Add Gmail account</h3>
              <p class="text-base-content/70 text-small mt-1">
                Name the inbox before starting OAuth.
              </p>
            </div>
            <.form
              for={@gmail_form}
              id="settings-add-gmail-form"
              method="get"
              action={~p"/integrations/gmail/connect"}
              class="grid gap-3 sm:grid-cols-[240px_auto]"
            >
              <.input
                field={@gmail_form[:label]}
                id="settings-add-gmail-label"
                label="Label"
                placeholder="Firm intake"
                class="border-base-300 rounded-field text-small w-full border px-3 py-2"
              />
              <.button
                type="submit"
                id="settings-add-gmail"
                size="sm"
                class="btn-soft mt-6"
              >
                <.icon name="hero-plus" class="size-4" /> Add Gmail
              </.button>
            </.form>
          </div>
        </.settings_panel>

        <.settings_panel title="Connected accounts" class="overflow-hidden" body_class="-mx-5 -mb-5">
          <div id="settings-connection-list" class="divide-base-300 divide-y">
            <div :if={@connections == []} id="settings-connections-empty" class="px-5 py-8">
              <p class="text-base-content/70 text-small">No connectors yet.</p>
            </div>

            <article
              :for={connection <- @connections}
              id={"settings-connection-#{connection.id}"}
              class="grid gap-4 px-5 py-4 xl:grid-cols-[1fr_380px]"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <.badge variant="neutral" class="uppercase">{connection.provider}</.badge>
                  <.badge variant={connection_status_variant(connection)}>
                    {connection_status(connection)}
                  </.badge>
                </div>
                <h4 class="text-base-content text-small mt-2 truncate font-semibold">
                  {Connection.display_label(connection)}
                </h4>
                <p class="text-base-content/70 text-small mt-1 truncate">
                  {connection.external_account_id}
                </p>
                <p class="text-base-content/60 text-micro mt-2">
                  Last sync: {last_sync_label(connection.last_synced_at)}
                </p>
                <p :if={connection.last_error} class="text-error text-fine mt-2">
                  {connection.last_error}
                </p>
              </div>

              <div class="space-y-3">
                <.form
                  for={to_form(connection_form_data(connection), as: :connection)}
                  id={"settings-connection-form-#{connection.id}"}
                  phx-submit="update_connection"
                  phx-value-id={connection.id}
                  class="grid gap-3 sm:grid-cols-2"
                >
                  <.input
                    field={to_form(connection_form_data(connection), as: :connection)[:label]}
                    id={"settings-connection-label-#{connection.id}"}
                    label="Label"
                    class="border-base-300 rounded-field text-small w-full border px-3 py-2"
                  />
                  <div class="flex flex-wrap items-center gap-2 sm:col-span-2">
                    <.button
                      type="submit"
                      id={"settings-save-connection-#{connection.id}"}
                      variant="soft"
                      size="sm"
                    >
                      <.icon name="hero-check" class="size-4" /> Save
                    </.button>
                    <.button
                      type="button"
                      id={"settings-sync-connection-#{connection.id}"}
                      phx-click="sync_now"
                      phx-value-id={connection.id}
                      variant="soft"
                      size="sm"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Sync
                    </.button>
                    <.button
                      :if={connection.status == "active"}
                      type="button"
                      id={"settings-disconnect-connection-#{connection.id}"}
                      phx-click="disconnect"
                      phx-value-id={connection.id}
                      variant="error"
                      size="sm"
                      class="btn-soft"
                    >
                      <.icon name="hero-no-symbol" class="size-4" /> Disconnect
                    </.button>
                    <.button
                      :if={connection.status != "active"}
                      type="button"
                      id={"settings-reconnect-connection-#{connection.id}"}
                      phx-click="reconnect"
                      phx-value-id={connection.id}
                      variant="soft"
                      size="sm"
                    >
                      <.icon name="hero-link" class="size-4" /> Reconnect
                    </.button>
                  </div>
                </.form>
              </div>
            </article>
          </div>
        </.settings_panel>
      </div>
    </Layouts.settings>
    """
  end

  defp load_connector_state(%{assigns: %{current_scope: %{current_org: nil}}} = socket) do
    assign(socket, :connections, [])
  end

  defp load_connector_state(socket) do
    org = socket.assigns.current_scope.current_org
    assign(socket, :connections, Integrations.list_connections(org.id))
  end

  defp fetch_current_org_connection(socket, id) do
    org_id = socket.assigns.current_scope.current_org.id

    with {id, ""} <- Integer.parse(id),
         {:ok, connection} <- Integrations.get_connection(id),
         true <- connection.org_id == org_id do
      {:ok, connection}
    else
      _error -> {:error, :not_found}
    end
  end

  defp connection_params(params) do
    %{label: params["label"]}
  end

  defp connection_form_data(connection) do
    %{"label" => connection.label || ""}
  end

  defp connection_status(%{status: "active", last_status: "connected"}), do: "connected"
  defp connection_status(%{status: "disconnected"}), do: "disconnected"
  defp connection_status(%{last_status: last_status}), do: last_status

  defp connection_status_variant(%{status: "active", last_status: "connected"}), do: "success"
  defp connection_status_variant(_connection), do: "warning"

  defp last_sync_label(nil), do: "Never"

  defp last_sync_label(datetime), do: Nila.Formatters.format_display_datetime_with_time(datetime)
end
