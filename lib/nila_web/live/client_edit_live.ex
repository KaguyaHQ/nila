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

        {:ok,
         socket
         |> assign(:page_title, "Edit client")
         |> assign(:client, client)
         |> assign(:tally_company, tally_company)
         |> assign(:available_tally_companies, TallyDevices.list_importable_companies(org.id))
         |> assign(:form, to_form(Clients.change_client(client)))}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Client not found.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  @impl true
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

  defp update_client(client, %{"tally_company_id" => company_id} = params)
       when company_id not in [nil, ""] do
    with {company_id, ""} <- Integer.parse(company_id) do
      TallyDevices.update_client_and_link_company(client, company_id, params)
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

  defp tally_company_options(companies) do
    Enum.map(companies, fn company ->
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
      <div id="client-edit-page" class="space-y-section mx-auto max-w-2xl">
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
            <.input field={@form[:pan]} label="PAN (optional)" />

            <.input
              :if={@available_tally_companies != []}
              field={@form[:tally_company_id]}
              type="select"
              label={
                if @tally_company,
                  do: "Change Tally company (optional)",
                  else: "Connect Tally company (optional)"
              }
              prompt={if @tally_company, do: "Keep current company", else: "Not connected"}
              options={tally_company_options(@available_tally_companies)}
            />

            <div :if={@tally_company} class="space-y-1">
              <p class="text-base-content text-ui font-semibold">Tally company</p>
              <p class="text-ink-muted text-ui">
                {@tally_company.name} · {@tally_company.device.name}
              </p>
            </div>

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
      </div>
    </Layouts.app>
    """
  end
end
