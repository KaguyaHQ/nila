defmodule NilaWeb.Settings.WorkspaceLive do
  use NilaWeb, :live_view

  alias Nila.Orgs
  alias Nila.Orgs.Org

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Firm settings")
      |> assign(:settings_section, :workspace)
      |> assign(:dirty, false)
      |> load_firm()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_firm", %{"org" => params}, socket) do
    changeset =
      socket.assigns.current_scope.current_org
      |> Orgs.change_org(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:firm_form, to_form(changeset, as: :org))
     |> assign(:dirty, changeset.changes != %{})}
  end

  @impl true
  def handle_event("save_firm", %{"org" => params}, socket) do
    case Orgs.update_org(socket.assigns.current_scope.current_org, params) do
      {:ok, org} ->
        {:noreply,
         socket
         |> put_flash(:info, "Firm details saved.")
         |> update_scope_org(org)
         |> load_firm()}

      {:error, changeset} ->
        {:noreply, assign(socket, :firm_form, to_form(changeset, as: :org))}
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
      <div id="settings-workspace" class="space-y-6">
        <.settings_header title="Firm">
          Your firm's identity on the returns you file for clients: legal name, GSTIN,
          registered address, and contact details.
        </.settings_header>

        <%= if @current_scope.current_org do %>
          <.settings_panel title="Firm details">
            <.form
              for={@firm_form}
              id="settings-firm-form"
              phx-change="validate_firm"
              phx-submit="save_firm"
              class="space-y-6"
            >
              <.form_section title="Identity">
                <div class="grid gap-4 md:grid-cols-2">
                  <.input field={@firm_form[:name]} label="Firm name" required />
                  <.input field={@firm_form[:legal_name]} label="Legal name" />
                  <.input
                    field={@firm_form[:gstin]}
                    label="GSTIN"
                    maxlength="15"
                    hint="15-character GST identification number"
                  />
                  <.input field={@firm_form[:contact_email]} type="email" label="Contact email" />
                  <.input field={@firm_form[:contact_phone]} label="Contact phone" />
                </div>
              </.form_section>

              <.form_section title="Address">
                <div class="grid gap-4 md:grid-cols-2">
                  <.input field={@firm_form[:address_line1]} label="Address line 1" />
                  <.input field={@firm_form[:address_line2]} label="Address line 2" />
                  <.input field={@firm_form[:city]} label="City" />
                  <.input
                    field={@firm_form[:state]}
                    type="select"
                    label="State"
                    prompt="Choose state"
                    options={Org.indian_states()}
                  />
                  <.input
                    field={@firm_form[:postal_code]}
                    label="Postal code"
                    hint="6-digit PIN code"
                  />
                  <.input field={@firm_form[:country]} label="Country" />
                </div>
              </.form_section>

              <.form_actions>
                <.save_button id="settings-save-firm" label="Save changes" disabled={!@dirty} />
              </.form_actions>
            </.form>
          </.settings_panel>
        <% else %>
          <.settings_panel class="p-6">
            <p class="text-ink-muted text-small">
              Create a firm before configuring its details.
            </p>
          </.settings_panel>
        <% end %>
      </div>
    </Layouts.settings>
    """
  end

  defp load_firm(%{assigns: %{current_scope: %{current_org: nil}}} = socket) do
    assign(socket, :firm_form, to_form(Orgs.change_org(%Org{}), as: :org))
  end

  defp load_firm(socket) do
    org = socket.assigns.current_scope.current_org

    socket
    |> assign(:firm_form, to_form(Orgs.change_org(org), as: :org))
    |> assign(:dirty, false)
  end

  defp update_scope_org(socket, org) do
    scope = %{socket.assigns.current_scope | current_org: org}
    assign(socket, :current_scope, scope)
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp form_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <h4 class="text-ink-subtle text-label font-semibold uppercase">
        {@title}
      </h4>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
