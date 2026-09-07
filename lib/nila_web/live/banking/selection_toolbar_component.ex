defmodule NilaWeb.Banking.SelectionToolbarComponent do
  @moduledoc """
  Isolates selection patches from the statement's transaction table.
  Selection and accounting actions remain owned by the parent LiveView.
  """
  use NilaWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       selected_count: 0,
       selected_active_count: 0,
       selected_ignored_count: 0,
       selected_ids: [],
       show_voucher_type: false,
       voucher_type_form: to_form(%{"voucher_type" => ""}, as: :voucher_type)
     )}
  end

  @impl true
  def update(%{selected_ids: ids} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:show_voucher_type, false)
     |> push_event("banking-selection", %{ids: ids})}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("open-voucher-type", _params, socket) do
    if socket.assigns.can_edit and socket.assigns.selected_count > 0 and
         socket.assigns.selected_ignored_count == 0 do
      {:noreply,
       assign(socket,
         show_voucher_type: true,
         voucher_type_form: to_form(%{"voucher_type" => ""}, as: :voucher_type)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-voucher-type", _params, socket),
    do: {:noreply, assign(socket, :show_voucher_type, false)}

  def handle_event("change-voucher-type", %{"voucher_type" => %{"voucher_type" => type}}, socket)
      when type in ["payment_receipt", "contra"] do
    send(self(), {:change_bank_voucher_type, socket.assigns.selected_ids, type})
    {:noreply, socket}
  end

  def handle_event("change-voucher-type", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <Layouts.bottom_bar :if={@can_edit && @selected_count > 0}>
        <div
          id="banking-selection-toolbar"
          class="gap-related flex flex-wrap items-center"
        >
          <p
            id="banking-selected-transaction-count"
            class="text-ui min-w-20 font-semibold"
            aria-live="polite"
          >
            {@selected_count} selected on this page
          </p>

          <%= if @selected_ignored_count == 0 do %>
            <div class="gap-related flex items-center">
              <.picker_trigger
                id="banking-bulk-ledger-trigger"
                phx-click="open-bulk-ledger-picker"
                popovertarget="banking-ledger-picker"
                placeholder={is_nil(@bulk_ledger)}
                title={if @bulk_ledger, do: @bulk_ledger.name, else: "Choose ledger"}
                disabled={
                  not (@can_edit and @ledger_configured and @selected_active_count > 0 and
                         @selected_ignored_count == 0)
                }
              >
                {if @bulk_ledger, do: @bulk_ledger.name, else: "Choose ledger"}
              </.picker_trigger>

              <.input
                type="hidden"
                id="banking-counter-ledger"
                form="banking-transaction-form"
                name="counter_ledger_identity"
                value={if @bulk_ledger, do: @bulk_ledger.identity, else: ""}
              />
              <.button
                id="banking-assign-selected"
                type="submit"
                form="banking-transaction-form"
                name="action"
                value="map"
                variant="outline"
                disabled={is_nil(@bulk_ledger)}
              >
                Assign
              </.button>
            </div>
          <% else %>
            <.badge variant="neutral">
              {if @selected_active_count > 0, do: "Mixed statuses", else: "Ignored"}
            </.badge>
          <% end %>

          <div class="gap-related ml-auto flex items-center">
            <.action_menu id="banking-more" label="More selection actions" trigger_label="More">
              <:item
                :if={@selected_ignored_count == 0}
                id="banking-change-voucher-type"
                label="Change voucher type"
                on_click="open-voucher-type"
                target={@myself}
              />
              <:item
                :if={@selected_active_count > 0}
                id="banking-ignore-selected"
                label={if @selected_ignored_count > 0, do: "Ignore active", else: "Ignore selected"}
                form="banking-transaction-form"
                name="action"
                value="ignore"
              />
              <:item
                :if={@selected_ignored_count > 0}
                id="banking-restore-selected"
                label={if @selected_active_count > 0, do: "Restore ignored", else: "Restore selected"}
                form="banking-transaction-form"
                name="action"
                value="restore"
              />
            </.action_menu>

            <.button
              :if={@selected_ignored_count == 0}
              type="submit"
              form="banking-transaction-form"
              name="action"
              value="send"
              id="banking-send-tally"
              disabled={not @balance_check_passed}
            >
              Send selected to Tally
            </.button>
          </div>
        </div>
      </Layouts.bottom_bar>

      <.modal
        :if={@show_voucher_type && @selected_count > 0}
        id="banking-voucher-type-modal"
        title="Change voucher type"
        on_close="close-voucher-type"
        target={@myself}
        return_focus="#banking-more-trigger"
      >
        <p class="mb-block text-ui">
          Applies to {@selected_count} selected {if @selected_count == 1,
            do: "transaction",
            else: "transactions"}. Counter-ledgers stay unchanged.
        </p>
        <.form
          for={@voucher_type_form}
          id="banking-voucher-type-form"
          phx-submit="change-voucher-type"
          phx-target={@myself}
        >
          <.input
            field={@voucher_type_form[:voucher_type]}
            type="select"
            label="Voucher type"
            prompt="Choose voucher type"
            options={[{"Payment / Receipt", "payment_receipt"}, {"Contra", "contra"}]}
            required
          />
          <p class="mt-related text-ink-muted text-ui">
            Payment / Receipt for ordinary transactions; Contra for transfers between bank or cash accounts.
            Direction follows each transaction’s amount.
          </p>
        </.form>
        <:footer>
          <.button
            id="banking-cancel-voucher-type"
            type="button"
            variant="ghost"
            phx-click="close-voucher-type"
            phx-target={@myself}
          >
            Cancel
          </.button>
          <.button id="banking-apply-voucher-type" type="submit" form="banking-voucher-type-form">
            Apply
          </.button>
        </:footer>
      </.modal>
    </div>
    """
  end
end
