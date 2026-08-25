defmodule NilaWeb.Settings.WorkspaceLive do
  use NilaWeb, :live_view

  on_mount {NilaWeb.UserAuth, {:authorize, :manage_settings}}

  alias Nila.Orgs
  alias Nila.Orgs.Org

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Firm settings")
      |> assign(:settings_section, :workspace)
      |> load_firm()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_firm", %{"org" => params}, socket) do
    changeset =
      socket.assigns.current_scope.current_org
      |> Orgs.change_org(firm_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :firm_form, to_form(changeset, as: :org))}
  end

  @impl true
  def handle_event("save_firm", %{"org" => params}, socket) do
    case Orgs.update_org(socket.assigns.current_scope.current_org, firm_params(params)) do
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
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div id="settings-workspace" class="space-y-section">
        <.settings_header title="Firm">
          Shared details Nila uses for your firm.
        </.settings_header>

        <%= if @current_scope.current_org do %>
          <.settings_panel class="max-w-2xl">
            <.form
              for={@firm_form}
              id="settings-firm-form"
              phx-change="validate_firm"
              phx-submit="save_firm"
              class="space-y-block"
            >
              <div class="grid gap-4 md:grid-cols-2">
                <.input field={@firm_form[:name]} label="Firm name" required />
                <.input field={@firm_form[:contact_phone]} label="Contact phone" />
              </div>

              <.button type="submit" id="settings-save-firm">Save changes</.button>
            </.form>
          </.settings_panel>
        <% else %>
          <.settings_panel>
            <p class="text-ink-muted text-ui">
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

    assign(socket, :firm_form, to_form(Orgs.change_org(org), as: :org))
  end

  defp update_scope_org(socket, org) do
    scope = %{socket.assigns.current_scope | current_org: org}
    assign(socket, :current_scope, scope)
  end

  defp firm_params(params), do: Map.take(params, ["name", "contact_phone"])
end
