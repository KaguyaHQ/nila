defmodule NilaWeb.ClientEditLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.TallyDevices

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case Clients.get_client(org.id, id) do
      {:ok, client} ->
        tally_company = linked_company(org.id, client.id)
        form_attrs = %{tally_company_id: tally_company && tally_company.id}

        {:ok,
         socket
         |> assign(:page_title, "Edit client")
         |> assign(:client, client)
         |> assign(
           :can_manage_gst,
           Nila.Accounts.Policy.can?(socket.assigns.current_scope, :manage_connectors)
         )
         |> load_gst_connection()
         |> assign(:tally_company, tally_company)
         |> assign(:available_tally_companies, TallyDevices.list_importable_companies(org.id))
         |> assign(:form, to_form(Clients.change_client(client, form_attrs)))}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Client not found.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  @impl true
  def handle_event("connect-gst", _, %{assigns: %{can_manage_gst: true}} = socket) do
    send_update(NilaWeb.Gst.ConnectionComponent,
      id: "gst-connection",
      request: %{
        client_id: socket.assigns.client.id,
        continuation: :manage,
        return_focus: "#client-gst-connect"
      }
    )

    {:noreply, socket}
  end

  def handle_event("disconnect-gst", _, socket) do
    case Nila.Gst.Portal.disconnect(socket.assigns.current_scope, socket.assigns.client.id) do
      :ok ->
        {:noreply,
         socket
         |> load_gst_connection()
         |> put_flash(:info, "GST account disconnected. Saved files are still available.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Your role cannot disconnect GST accounts.")}
    end
  end

  def handle_event("connect-gst", _, socket), do: {:noreply, socket}

  def handle_event("validate", %{"client" => params}, socket) do
    changeset =
      socket.assigns.client
      |> Clients.change_client(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case update_client(socket.assigns.client, params) do
      {:ok, _client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Client updated.")
         |> push_navigate(to: ~p"/clients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :not_found} ->
        changeset =
          socket.assigns.client
          |> Clients.change_client(params)
          |> Ecto.Changeset.add_error(
            :tally_company_id,
            "is no longer available — choose another company"
          )
          |> Map.put(:action, :update)

        {:noreply,
         socket
         |> assign(
           :available_tally_companies,
           TallyDevices.list_importable_companies(socket.assigns.client.org_id)
         )
         |> assign(:form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:gst_connected, _client_id, :manage}, socket) do
    {:noreply, socket |> load_gst_connection() |> put_flash(:info, "GST account connected.")}
  end

  defp load_gst_connection(socket) do
    connection =
      case Nila.Gst.Portal.connection(
             socket.assigns.current_scope.current_org.id,
             socket.assigns.client.id
           ) do
        {:ok, connection} -> connection
        _ -> nil
      end

    assign(socket,
      gst_connection: connection,
      gst_expired: connection && Nila.Gst.Portal.session_expired?(connection, DateTime.utc_now())
    )
  end

  defp update_client(client, %{"tally_company_id" => company_id} = params)
       when company_id not in [nil, ""] do
    with {company_id, ""} <- Integer.parse(company_id) do
      if client.active_tally_company_id == company_id do
        Clients.update_client(client, params)
      else
        TallyDevices.update_client_and_link_company(client, company_id, params)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp update_client(client, params), do: Clients.update_client(client, params)

  defp linked_company(org_id, client_id) do
    org_id
    |> TallyDevices.list_linked_companies()
    |> Enum.find(&(&1.client.id == client_id))
  end

  defp tally_company_options(current_company, available_companies) do
    current_company
    |> List.wrap()
    |> Kernel.++(available_companies)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn company ->
      {"#{company.name} · #{company.device.name}", company.id}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="client-edit-page" class="space-y-block mx-auto max-w-2xl">
        <.page_header eyebrow="Clients" eyebrow_path={~p"/clients"} title="Edit client" />
        <.card>
          <.form
            for={@form}
            id="client-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-block"
          >
            <.input field={@form[:name]} label="Client name" required />
            <.input field={@form[:gstin]} label="GSTIN (optional)" />
            <section id="client-tally" class="border-rule pt-block border-t">
              <.input
                field={@form[:tally_company_id]}
                type="select"
                label="Tally company"
                prompt="Not connected"
                options={tally_company_options(@tally_company, @available_tally_companies)}
              />
            </section>

            <div class="flex items-center gap-3">
              <.button type="submit" id="client-submit">Save changes</.button>
              <.link
                navigate={~p"/clients"}
                id="client-cancel"
                class="text-ink-muted text-ui font-semibold"
              >
                Cancel
              </.link>
            </div>
          </.form>
        </.card>

        <.card id="client-gst-access">
          <section class="space-y-block" aria-labelledby="client-gst-heading">
            <h2 id="client-gst-heading" class="text-h4">GST portal access</h2>

            <p :if={@gst_connection} id="client-gst-username" class="text-ui">
              Username: {@gst_connection.username}
            </p>

            <p id="client-gst-status" class="text-ink-muted text-ui">
              {cond do
                !Nila.Gstin.valid?(@client.gstin) ->
                  "Save a valid GSTIN before connecting."

                !@gst_connection ->
                  "Not connected. You can also connect when fetching GSTR-2B or checking notices."

                @gst_expired ->
                  "Session expired. Your saved GST account needs a fresh OTP."

                true ->
                  "Connected. GSTR-2B and notices use this account."
              end}
            </p>

            <p :if={!@can_manage_gst} class="text-ink-muted text-ui">
              Ask the workspace owner to manage GST portal access.
            </p>

            <div class="flex flex-wrap gap-3">
              <.button
                id="client-gst-connect"
                phx-click="connect-gst"
                variant="soft"
                disabled={!@can_manage_gst || !Nila.Gstin.valid?(@client.gstin)}
              >
                {cond do
                  !@gst_connection -> "Connect GST"
                  @gst_expired -> "Reconnect GST"
                  true -> "Change GST login"
                end}
              </.button>

              <.button
                :if={@gst_connection}
                id="client-gst-disconnect"
                phx-click="disconnect-gst"
                variant="ghost"
                disabled={!@can_manage_gst}
              >Disconnect GST</.button>
            </div>
          </section>
        </.card>
      </div>

      <.live_component
        module={NilaWeb.Gst.ConnectionComponent}
        id="gst-connection"
        current_scope={@current_scope}
      />
    </Layouts.app>
    """
  end
end
