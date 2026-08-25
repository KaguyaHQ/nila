defmodule NilaWeb.ClientNewLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.TallyDevices

  @impl true
  def mount(_params, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    {:ok,
     socket
     |> assign(:page_title, "Add client")
     |> assign(:tally_companies, TallyDevices.list_importable_companies(org_id))
     |> assign(:form, client_form(org_id))}
  end

  @impl true
  def handle_event("validate", %{"client" => params}, socket) do
    org_id = socket.assigns.current_scope.current_org.id
    params = prefill_from_tally(params, socket.assigns.tally_companies)

    changeset =
      %Client{}
      |> Clients.change_client(client_attrs(params, org_id))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"client" => params}, socket) do
    org = socket.assigns.current_scope.current_org
    params = prefill_from_tally(params, socket.assigns.tally_companies)
    attrs = client_attrs(params, org.id)

    case create_client(org.id, attrs) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{client.name} added.")
         |> push_navigate(to: ~p"/clients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :not_found} ->
        changeset =
          %Client{}
          |> Clients.change_client(attrs)
          |> Ecto.Changeset.add_error(
            :tally_company_id,
            "is no longer available — choose another company"
          )
          |> Map.put(:action, :insert)

        {:noreply,
         socket
         |> assign(:tally_companies, TallyDevices.list_importable_companies(org.id))
         |> assign(:form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Client could not be added. Try again.")}
    end
  end

  defp client_form(org_id) do
    %Client{}
    |> Clients.change_client(%{
      "org_id" => org_id,
      "type" => "company",
      "chase_channel" => "none"
    })
    |> to_form()
  end

  defp client_attrs(params, org_id) do
    params
    |> Map.put("org_id", org_id)
    |> Map.put("type", "company")
    |> Map.put("chase_channel", "none")
  end

  defp create_client(org_id, %{"tally_company_id" => company_id} = attrs)
       when company_id not in [nil, ""] do
    with {company_id, ""} <- Integer.parse(company_id) do
      TallyDevices.create_client_from_company(org_id, company_id, attrs)
    else
      _ -> {:error, :not_found}
    end
  end

  defp create_client(_org_id, attrs), do: Clients.create_client(attrs)

  defp tally_company_options(companies) do
    Enum.map(companies, fn company ->
      {"#{company.name} · #{company.device.name}", company.id}
    end)
  end

  defp prefill_from_tally(params, companies) do
    company =
      Enum.find(companies, fn company ->
        to_string(company.id) == to_string(params["tally_company_id"])
      end)

    case company do
      nil ->
        params

      company ->
        params
        |> put_if_blank("name", company.name)
        |> put_if_blank("gstin", company.gstin)
    end
  end

  defp put_if_blank(params, _key, nil), do: params

  defp put_if_blank(params, key, value) do
    if params[key] in [nil, ""], do: Map.put(params, key, value), else: params
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="client-new-page" class="space-y-section mx-auto max-w-2xl">
        <.page_header eyebrow="Clients" eyebrow_path={~p"/clients"} title="Add client" />

        <.card>
          <.form
            for={@form}
            id="client-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-block"
          >
            <div :if={@tally_companies != []} class="space-y-related">
              <.input
                field={@form[:tally_company_id]}
                type="select"
                label="Tally company (optional)"
                prompt="Select from Nila Connector"
                options={tally_company_options(@tally_companies)}
              />
              <p class="text-ink-muted text-ui">
                Select one to fill the client details, or add the client manually.
              </p>
            </div>

            <.input
              field={@form[:name]}
              label="Client name"
              placeholder="Caltech Refrigeration"
              autocomplete="organization"
              required
            />
            <.input field={@form[:gstin]} label="GSTIN (optional)" />

            <div class="flex items-center gap-3">
              <.button type="submit" id="client-submit">
                <.icon name="hero-plus" class="size-4" /> Add client
              </.button>
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
