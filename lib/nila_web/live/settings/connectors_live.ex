defmodule NilaWeb.Settings.ConnectorsLive do
  use NilaWeb, :live_view

  alias Nila.Integrations
  alias Nila.Integrations.{Connection, WhatsAppSignup}

  @whatsapp_signup_salt "whatsapp_embedded_signup"
  @signup_max_age 300

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Connector settings")
     |> assign(:settings_section, :connectors)
     |> assign(:gmail_form, to_form(%{}, as: :connection))
     |> assign(:microsoft_form, to_form(%{}, as: :connection))
     |> assign_whatsapp_signup()
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
  def handle_event(
        "whatsapp_signup_complete",
        %{
          "authorization_code" => authorization_code,
          "session" => session,
          "transaction" => transaction
        } = params,
        socket
      ) do
    transaction_result = verify_whatsapp_transaction(socket, transaction)
    socket = assign_whatsapp_transaction(socket)

    with :ok <- transaction_result,
         :ok <- validate_signup_payload(authorization_code, session),
         :ok <-
           verify_reconnect_target(socket, params["connection_id"], session["phone_number_id"]) do
      case Integrations.complete_whatsapp_signup(
             socket.assigns.current_scope.current_org.id,
             authorization_code,
             session
           ) do
        {:ok, _connection} ->
          {:reply, %{ok: true},
           socket
           |> put_flash(:info, "WhatsApp connected and subscribed to webhooks.")
           |> load_connector_state()}

        {:error, _reason} ->
          {:reply, %{ok: false}, put_flash(socket, :error, "WhatsApp connection failed.")}
      end
    else
      _error ->
        {:reply, %{ok: false}, put_flash(socket, :error, "WhatsApp connection failed.")}
    end
  end

  def handle_event("whatsapp_signup_complete", _params, socket) do
    socket = assign_whatsapp_transaction(socket)
    {:reply, %{ok: false}, put_flash(socket, :error, "WhatsApp connection failed.")}
  end

  @impl true
  def handle_event("verify_whatsapp", %{"id" => id}, socket) do
    with {:ok, %{provider: "whatsapp"} = connection} <-
           fetch_current_org_connection(socket, id) do
      case Integrations.verify_whatsapp_connection(connection) do
        {:ok, _connection} ->
          {:noreply,
           socket
           |> put_flash(:info, "WhatsApp token, phone, and webhook subscription are ready.")
           |> load_connector_state()}

        {:error, _reason} ->
          _ = Integrations.mark_degraded(connection, :whatsapp_readiness_check_failed)

          {:noreply,
           socket
           |> put_flash(:error, "WhatsApp readiness check failed.")
           |> load_connector_state()}
      end
    else
      _error ->
        {:noreply, put_flash(socket, :error, "WhatsApp readiness check failed.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.settings
      flash={@flash}
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div
        id="settings-connectors"
        class="space-y-section"
        phx-hook={@whatsapp_signup_config && "WhatsAppEmbeddedSignup"}
        data-app-id={@whatsapp_signup_config && @whatsapp_signup_config.app_id}
        data-config-id={@whatsapp_signup_config && @whatsapp_signup_config.config_id}
        data-graph-version={@whatsapp_signup_config && @whatsapp_signup_config.graph_version}
        data-transaction={@whatsapp_signup_transaction}
      >
        <.settings_header title="Connectors">
          Connect the inboxes and channels documents arrive on. Labels show up in
          operational views so the team can tell the firm's intake channels apart.
        </.settings_header>

        <section
          :if={@connections != []}
          id="settings-connected-accounts"
          class="space-y-block"
        >
          <div class="space-y-related">
            <h2 class="text-base-content text-h4 font-semibold">Connected accounts</h2>
            <p class="text-ink-muted text-ui">
              Connection status, labels, and recent document activity.
            </p>
          </div>

          <div
            id="settings-connection-list"
            class="border-base-300 divide-base-300 divide-y border-y"
          >
            <article
              :for={connection <- @connections}
              id={"settings-connection-#{connection.id}"}
              class="gap-block py-block grid min-w-0 xl:grid-cols-[minmax(0,1fr)_380px]"
            >
              <div class="space-y-related min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <.badge variant="neutral">{String.upcase(connection.provider)}</.badge>
                  <.badge variant={connection_status_variant(connection)}>
                    {connection_status(connection)}
                  </.badge>
                </div>
                <h3 class="text-base-content text-ui font-semibold wrap-break-word">
                  {Connection.display_label(connection)}
                </h3>
                <p class="text-ink-muted text-ui wrap-break-word">
                  {connection_detail(connection)}
                </p>
                <p
                  :if={connection.provider == "whatsapp" && connection.settings["waba_id"]}
                  class="text-ink-subtle text-ui wrap-break-word"
                >
                  WABA {connection.settings["waba_id"]} · Phone ID {connection.external_account_id}
                </p>
                <p class="text-base-content text-ui font-medium">
                  {activity_label(connection)}: {last_sync_label(connection.last_synced_at)}
                </p>
                <p :if={connection.last_error} class="nila-connector-error text-body">
                  {connection.last_error}
                </p>
              </div>

              <.form
                for={to_form(connection_form_data(connection), as: :connection)}
                id={"settings-connection-form-#{connection.id}"}
                phx-submit="update_connection"
                phx-value-id={connection.id}
                class="space-y-related"
              >
                <.input
                  field={to_form(connection_form_data(connection), as: :connection)[:label]}
                  id={"settings-connection-label-#{connection.id}"}
                  label="Label"
                />
                <div class="flex flex-wrap items-center gap-2">
                  <.button
                    type="submit"
                    id={"settings-save-connection-#{connection.id}"}
                    variant="ghost"
                    size="sm"
                  >
                    <.icon name="hero-check" class="size-4" /> Save
                  </.button>
                  <.button
                    :if={connection.provider == "whatsapp" && connection.status == "active"}
                    type="button"
                    id={"settings-verify-connection-#{connection.id}"}
                    phx-click="verify_whatsapp"
                    phx-value-id={connection.id}
                    variant="soft"
                    size="sm"
                  >
                    <.icon name="hero-check-circle" class="size-4" /> Verify readiness
                  </.button>
                  <.button
                    :if={connection.status == "active"}
                    type="button"
                    id={"settings-disconnect-connection-#{connection.id}"}
                    phx-click="disconnect"
                    phx-value-id={connection.id}
                    data-confirm="Disconnect this account from Nila?"
                    variant="ghost"
                    size="sm"
                  >
                    <.icon name="hero-no-symbol" class="size-4" /> Disconnect
                  </.button>
                  <.button
                    :if={connection.status != "active" && connection.provider != "whatsapp"}
                    type="button"
                    id={"settings-reconnect-connection-#{connection.id}"}
                    phx-click="reconnect"
                    phx-value-id={connection.id}
                    variant="soft"
                    size="sm"
                  >
                    <.icon name="hero-link" class="size-4" /> Reconnect
                  </.button>
                  <.button
                    :if={
                      connection.status != "active" && connection.provider == "whatsapp" &&
                        @whatsapp_signup_config
                    }
                    type="button"
                    id={"settings-reconnect-connection-#{connection.id}"}
                    data-whatsapp-launch
                    data-whatsapp-connection-id={connection.id}
                    variant="soft"
                    size="sm"
                  >
                    <.icon name="hero-link" class="size-4" /> Reconnect with Meta
                  </.button>
                </div>
              </.form>
            </article>
          </div>
        </section>

        <section id="settings-add-channel" class="space-y-block">
          <div class="space-y-related">
            <h2 class="text-base-content text-h4 font-semibold">Add a channel</h2>
            <p class="text-ink-muted text-ui">
              Choose where documents arrive. Configure only the channel you want to add.
            </p>
          </div>

          <div class="border-base-300 divide-base-300 divide-y border-y">
            <details id="settings-add-gmail-disclosure" name="settings-add-provider" class="group">
              <summary class="hover:text-ink py-block text-base-content text-ui flex cursor-pointer list-none items-center gap-3">
                <div class="space-y-related min-w-0 flex-1">
                  <h3 class="font-semibold">Gmail</h3>
                  <p class="text-ink-muted text-ui">Receive documents from a Google inbox.</p>
                </div>
                <.icon
                  name="hero-chevron-down-mini"
                  class="text-ink-faint size-4 shrink-0 transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="border-base-300 pb-block pt-block border-t">
                <.form
                  for={@gmail_form}
                  id="settings-add-gmail-form"
                  method="get"
                  action={~p"/integrations/gmail/connect"}
                  class="grid items-end gap-3 sm:grid-cols-[minmax(0,240px)_auto] sm:justify-start"
                >
                  <.input
                    field={@gmail_form[:label]}
                    id="settings-add-gmail-label"
                    label="Label"
                    placeholder="Firm intake"
                  />
                  <.button type="submit" id="settings-add-gmail" variant="soft" size="sm">
                    <.icon name="hero-plus" class="size-4" /> Add Gmail
                  </.button>
                </.form>
              </div>
            </details>

            <details
              id="settings-add-microsoft-disclosure"
              name="settings-add-provider"
              class="group"
            >
              <summary class="hover:text-ink py-block text-base-content text-ui flex cursor-pointer list-none items-center gap-3">
                <div class="space-y-related min-w-0 flex-1">
                  <h3 class="font-semibold">Microsoft 365</h3>
                  <p class="text-ink-muted text-ui">
                    Receive and send documents through a shared mailbox.
                  </p>
                </div>
                <.icon
                  name="hero-chevron-down-mini"
                  class="text-ink-faint size-4 shrink-0 transition-transform group-open:rotate-180"
                />
              </summary>
              <div class="border-base-300 pb-block pt-block space-y-block border-t">
                <p class="text-ink-muted text-ui max-w-2xl">
                  Nila sends from a shared mailbox once the firm's Microsoft admin approves.
                  Restrict the app to this mailbox in Exchange, or it can send as any mailbox
                  in the tenant.
                </p>
                <.form
                  for={@microsoft_form}
                  id="settings-add-microsoft-form"
                  method="get"
                  action={~p"/integrations/microsoft/connect"}
                  class="space-y-block"
                >
                  <div class="grid gap-4 sm:grid-cols-3">
                    <.input
                      field={@microsoft_form[:tenant_id]}
                      id="settings-add-microsoft-tenant"
                      label="Directory (tenant) ID"
                      placeholder="00000000-0000-0000-0000-000000000000"
                    />
                    <.input
                      field={@microsoft_form[:mailbox]}
                      id="settings-add-microsoft-mailbox"
                      label="Send from"
                      placeholder="mail@firm.com"
                    />
                    <.input
                      field={@microsoft_form[:label]}
                      id="settings-add-microsoft-label"
                      label="Label"
                      placeholder="Firm mailbox"
                    />
                  </div>
                  <.button type="submit" id="settings-add-microsoft" variant="soft" size="sm">
                    <.icon name="hero-plus" class="size-4" /> Start Microsoft consent
                  </.button>
                </.form>
              </div>
            </details>

            <article class="gap-block py-block flex flex-col lg:flex-row lg:items-center lg:justify-between">
              <div class="space-y-related min-w-0">
                <h3 class="text-base-content text-ui font-semibold">WhatsApp</h3>
                <p class="text-ink-muted text-ui max-w-2xl">
                  Authorize Nila through Meta Embedded Signup. Nila verifies the selected business,
                  registers the number, and subscribes it to the existing webhook.
                </p>
                <p
                  :if={@whatsapp_signup_config}
                  data-whatsapp-signup-status
                  class="nila-whatsapp-status text-body text-ink-muted"
                >
                  Meta signup opens in a secure window.
                </p>
                <p
                  :if={!@whatsapp_signup_config}
                  id="settings-whatsapp-not-configured"
                  class="nila-whatsapp-config-warning text-body"
                >
                  Embedded Signup is not configured for this environment.
                </p>
              </div>
              <.button
                :if={@whatsapp_signup_config}
                type="button"
                id="settings-connect-whatsapp"
                data-whatsapp-launch
                variant="soft"
                size="sm"
              >
                <.icon name="hero-plus" class="size-4" /> Connect WhatsApp
              </.button>
            </article>
          </div>
        </section>
      </div>
    </Layouts.settings>
    """
  end

  defp assign_whatsapp_signup(%{assigns: %{current_scope: %{current_org: nil}}} = socket) do
    socket
    |> assign(:whatsapp_signup_config, nil)
    |> assign(:whatsapp_signup_transaction, nil)
  end

  defp assign_whatsapp_signup(socket) do
    case WhatsAppSignup.public_config() do
      {:ok, config} ->
        socket
        |> assign(:whatsapp_signup_config, config)
        |> assign_whatsapp_transaction()

      {:error, :whatsapp_embedded_signup_not_configured} ->
        socket
        |> assign(:whatsapp_signup_config, nil)
        |> assign(:whatsapp_signup_transaction, nil)
    end
  end

  defp assign_whatsapp_transaction(%{assigns: %{whatsapp_signup_config: nil}} = socket),
    do: assign(socket, :whatsapp_signup_transaction, nil)

  defp assign_whatsapp_transaction(socket) do
    scope = socket.assigns.current_scope

    transaction =
      Phoenix.Token.sign(NilaWeb.Endpoint, @whatsapp_signup_salt, %{
        "org_id" => scope.current_org.id,
        "user_id" => scope.user.id,
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      })

    assign(socket, :whatsapp_signup_transaction, transaction)
  end

  defp verify_whatsapp_transaction(socket, transaction) do
    scope = socket.assigns.current_scope

    with true <-
           is_binary(transaction) and transaction == socket.assigns.whatsapp_signup_transaction,
         {:ok, claims} <-
           Phoenix.Token.verify(NilaWeb.Endpoint, @whatsapp_signup_salt, transaction,
             max_age: @signup_max_age
           ),
         true <- claims["org_id"] == scope.current_org.id,
         true <- claims["user_id"] == scope.user.id do
      :ok
    else
      _error -> {:error, :invalid_whatsapp_signup_transaction}
    end
  end

  defp verify_reconnect_target(_socket, nil, _phone_number_id), do: :ok

  defp verify_reconnect_target(socket, connection_id, phone_number_id)
       when is_binary(connection_id) do
    with {:ok, %{provider: "whatsapp", status: "disconnected"} = connection} <-
           fetch_current_org_connection(socket, connection_id),
         true <- connection.external_account_id == phone_number_id do
      :ok
    else
      _error -> {:error, :whatsapp_reconnect_mismatch}
    end
  end

  defp verify_reconnect_target(_socket, _connection_id, _phone_number_id),
    do: {:error, :whatsapp_reconnect_mismatch}

  defp validate_signup_payload(authorization_code, session) do
    valid_code =
      is_binary(authorization_code) and authorization_code != "" and
        byte_size(authorization_code) <= 2048

    valid_session =
      is_map(session) and
        Enum.all?(~w(business_id waba_id phone_number_id), fn key ->
          value = session[key]
          is_binary(value) and byte_size(value) <= 64 and value =~ ~r/^\d+$/
        end)

    if valid_code and valid_session, do: :ok, else: {:error, :invalid_whatsapp_signup_payload}
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

  defp connection_detail(%{provider: "whatsapp", settings: settings} = connection),
    do: settings["display_phone_number"] || connection.external_account_id

  defp connection_detail(connection), do: connection.external_account_id

  defp activity_label(%{provider: "whatsapp"}), do: "Last received"
  defp activity_label(_connection), do: "Last sync"

  defp last_sync_label(nil), do: "Never"

  defp last_sync_label(datetime), do: Nila.Formatters.format_display_datetime_with_time(datetime)
end
