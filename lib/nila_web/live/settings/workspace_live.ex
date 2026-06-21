defmodule NilaWeb.Settings.WorkspaceLive do
  use NilaWeb, :live_view

  alias Nila.Orgs
  alias Nila.Orgs.Entity

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Workspace settings")
      |> assign(:settings_section, :workspace)
      |> assign(:selected_entity, nil)
      |> assign(:entity_form, to_form(Orgs.change_entity(%Entity{}), as: :entity))
      |> assign(:dirty, false)
      |> assign(:invoice_preview, nil)
      |> assign(:previous_entity_id, nil)
      |> load_entities()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_entity", %{"id" => id}, socket) do
    entity = Enum.find(socket.assigns.entities, &(&1.id == String.to_integer(id)))
    {:noreply, select_entity(socket, entity)}
  end

  @impl true
  def handle_event("new_entity", _params, socket) do
    org = socket.assigns.current_scope.current_org
    entity = %Entity{org_id: org.id, invoice_prefix: "", invoice_next: 1, invoice_padding: 0}

    socket =
      socket
      |> assign(:previous_entity_id, socket.assigns.selected_entity_id)

    {:noreply, select_entity(socket, entity)}
  end

  @impl true
  def handle_event("validate_entity", %{"entity" => params}, socket) do
    changeset =
      socket.assigns.selected_entity
      |> Orgs.change_entity(entity_params(socket, params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:entity_form, to_form(changeset, as: :entity))
     |> assign(:dirty, changeset.changes != %{})
     |> assign(:invoice_preview, invoice_preview(changeset))}
  end

  @impl true
  def handle_event("save_entity", %{"entity" => params}, socket) do
    entity = socket.assigns.selected_entity
    attrs = entity_params(socket, params)

    result =
      if entity.id do
        Orgs.update_entity(entity, attrs)
      else
        Orgs.create_entity(attrs)
      end

    case result do
      {:ok, entity} ->
        {:noreply,
         socket
         |> put_flash(:info, "Entity saved.")
         |> assign(:selected_entity_id, entity.id)
         |> load_entities()}

      {:error, changeset} ->
        {:noreply, assign(socket, :entity_form, to_form(changeset, as: :entity))}
    end
  end

  @impl true
  def handle_event("cancel_entity", _params, socket) do
    if is_nil(socket.assigns.selected_entity.id) do
      entity =
        with prev_id when is_integer(prev_id) <- socket.assigns.previous_entity_id,
             entity <- Enum.find(socket.assigns.entities, &(&1.id == prev_id)) do
          entity
        else
          _ -> List.first(socket.assigns.entities)
        end

      {:noreply, select_entity(socket, entity)}
    else
      {:noreply, select_entity(socket, socket.assigns.selected_entity)}
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
        <.settings_header title="Workspace">
          Manage the legal entities that share this family workspace. Each entity keeps its own
          GSTIN, bank account, address, contact details, and invoice sequence.
        </.settings_header>

        <%= if @current_scope.current_org do %>
          <div class="grid gap-6 xl:grid-cols-[minmax(240px,320px)_1fr]">
            <.settings_panel title="Entities" class="p-4">
              <:actions>
                <.button
                  type="button"
                  id="settings-new-entity"
                  phx-click="new_entity"
                  variant="soft"
                  size="sm"
                  class="btn-square"
                  aria-label="Add entity"
                >
                  <.icon name="hero-plus" class="size-4" />
                </.button>
              </:actions>

              <div id="settings-entity-list" class="mt-4 space-y-2">
                <div
                  :if={@selected_entity && is_nil(@selected_entity.id)}
                  class="w-full rounded-field border border-primary/30 bg-primary/10 px-3 py-2 text-left text-small shadow-moon"
                >
                  <span class="block truncate font-medium text-primary">New entity</span>
                  <span class="mt-0.5 block truncate text-fine text-primary/70">
                    Fill in details below
                  </span>
                </div>
                <.selectable_list_item
                  :for={entity <- @entities}
                  id={"settings-entity-#{entity.id}"}
                  phx-click="select_entity"
                  phx-value-id={entity.id}
                  active={@selected_entity && @selected_entity.id == entity.id}
                  data-confirm={@dirty && "Discard unsaved changes?"}
                >
                  <:title>{entity.name}</:title>
                  <:subtitle>{entity.gstin || "GSTIN pending"}</:subtitle>
                </.selectable_list_item>
              </div>
            </.settings_panel>

            <.settings_panel title={
              if @selected_entity && is_nil(@selected_entity.id),
                do: "New entity",
                else: @selected_entity && @selected_entity.name
            }>
              <.form
                for={@entity_form}
                id="settings-entity-form"
                phx-change="validate_entity"
                phx-submit="save_entity"
                class="space-y-6"
              >
                <div
                  id={"settings-entity-fields-#{@selected_entity_id || "new"}"}
                  class="moon-rise space-y-6"
                >
                  <.form_section title="Identity">
                    <div class="grid gap-4 md:grid-cols-2">
                      <.input field={@entity_form[:name]} label="Entity name" required />
                      <.input
                        field={@entity_form[:gstin]}
                        label="GSTIN"
                        maxlength="15"
                        hint="15-character GST identification number"
                      />
                      <.input field={@entity_form[:contact_email]} type="email" label="Contact email" />
                      <.input field={@entity_form[:contact_phone]} label="Contact phone" />
                    </div>
                  </.form_section>

                  <.form_section title="Address">
                    <div class="grid gap-4 md:grid-cols-2">
                      <.input field={@entity_form[:address_line1]} label="Address line 1" />
                      <.input field={@entity_form[:address_line2]} label="Address line 2" />
                      <.input field={@entity_form[:city]} label="City" />
                      <.input
                        field={@entity_form[:state]}
                        type="select"
                        label="State"
                        prompt="Choose state"
                        options={Entity.indian_states()}
                      />
                      <.input
                        field={@entity_form[:postal_code]}
                        label="Postal code"
                        hint="6-digit PIN code"
                      />
                      <.input field={@entity_form[:country]} label="Country" />
                    </div>
                  </.form_section>

                  <.form_section title="Banking">
                    <div class="grid gap-4 md:grid-cols-2">
                      <.input field={@entity_form[:bank_account_holder]} label="Account holder" />
                      <.input field={@entity_form[:bank_account_number]} label="Account number" />
                      <.input
                        field={@entity_form[:bank_ifsc]}
                        label="IFSC"
                        maxlength="11"
                        hint="11-character branch code"
                      />
                      <.input field={@entity_form[:bank_name]} label="Bank name" />
                    </div>
                  </.form_section>

                  <.form_section title="Invoice numbering">
                    <div class="grid gap-4 md:grid-cols-3">
                      <.input field={@entity_form[:invoice_prefix]} label="Invoice prefix" />
                      <.input
                        field={@entity_form[:invoice_next]}
                        type="number"
                        label="Next invoice number"
                        min="1"
                      />
                      <.input
                        field={@entity_form[:invoice_padding]}
                        type="number"
                        label="Padding"
                        min="0"
                        max="12"
                      />
                    </div>
                    <p
                      :if={@invoice_preview}
                      id="settings-invoice-preview"
                      class="mt-3 text-small text-base-content/70"
                    >
                      Next invoice will look like
                      <span class="ml-1 rounded-field bg-base-200 px-2 py-0.5 font-mono text-base-content">
                        {@invoice_preview}
                      </span>
                    </p>
                  </.form_section>
                </div>

                <.form_actions>
                  <.button
                    :if={@selected_entity && (@dirty || is_nil(@selected_entity.id))}
                    type="button"
                    id="settings-cancel-entity"
                    phx-click="cancel_entity"
                    variant="ghost"
                    size="sm"
                  >
                    {if is_nil(@selected_entity.id), do: "Cancel", else: "Discard changes"}
                  </.button>
                  <.save_button
                    id="settings-save-entity"
                    label={
                      if @selected_entity && is_nil(@selected_entity.id),
                        do: "Create entity",
                        else: "Save changes"
                    }
                    disabled={@selected_entity && @selected_entity.id && !@dirty}
                  />
                </.form_actions>
              </.form>
            </.settings_panel>
          </div>
        <% else %>
          <.settings_panel class="p-6">
            <p class="text-small text-base-content/70">
              Create a workspace before configuring entities.
            </p>
          </.settings_panel>
        <% end %>
      </div>
    </Layouts.settings>
    """
  end

  defp load_entities(%{assigns: %{current_scope: %{current_org: nil}}} = socket) do
    socket
    |> assign(:entities, [])
    |> assign(:selected_entity, nil)
  end

  defp load_entities(socket) do
    org = socket.assigns.current_scope.current_org
    default_entity = Orgs.get_or_create_default_entity!(org.id)
    entities = Orgs.list_entities(org.id)
    selected_id = socket.assigns[:selected_entity_id] || default_entity.id
    selected = Enum.find(entities, default_entity, &(&1.id == selected_id))

    socket
    |> assign(:entities, entities)
    |> assign(:selected_entity_id, selected.id)
    |> select_entity(selected)
  end

  defp select_entity(socket, nil), do: socket

  defp select_entity(socket, entity) do
    socket
    |> assign(:selected_entity, entity)
    |> assign(:selected_entity_id, entity.id)
    |> assign(:dirty, false)
    |> assign(:entity_form, to_form(Orgs.change_entity(entity), as: :entity))
    |> assign(:invoice_preview, Orgs.formatted_invoice_number(entity))
  end

  defp entity_params(socket, params) do
    Map.put(params, "org_id", socket.assigns.current_scope.current_org.id)
  end

  defp invoice_preview(changeset) do
    case Ecto.Changeset.apply_changes(changeset) do
      %Entity{invoice_next: next} = entity when is_integer(next) ->
        Orgs.formatted_invoice_number(entity)

      _ ->
        nil
    end
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp form_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <h4 class="text-label font-semibold uppercase text-base-content/50">
        {@title}
      </h4>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
