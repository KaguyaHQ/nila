defmodule NilaWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import NilaWeb.Components.Page
  import NilaWeb.Components.Card
  import NilaWeb.Components.Badge
  import NilaWeb.Components.Button
  import NilaWeb.Components.Input
  import NilaWeb.Components.Table
  import NilaWeb.Components.Fold
  import NilaWeb.Components.Feedback
  import NilaWeb.Layouts
  import NilaWeb.Components.Typography
  import NilaWeb.Components.SelectableList
  import NilaWeb.Components.LedgerPicker
  import NilaWeb.Components.Menu

  test "action menus support labelled triggers and external form actions alongside event actions" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.action_menu id="more" label="More selection actions" trigger_label="More">
        <:item id="change-type" label="Change voucher type" on_click="change-type" target={1} />
        <:item id="ignore" label="Ignore selected" form="transactions" name="action" value="ignore" />
      </.action_menu>
      <.action_menu id="row" label="Row actions">
        <:item id="edit-row" label="Edit" on_click="edit" value="123" />
      </.action_menu>
      """)

    fragment = LazyHTML.from_fragment(html)
    assert LazyHTML.text(LazyHTML.query(fragment, "#more-trigger")) =~ "More"

    assert [_] =
             LazyHTML.query(
               fragment,
               "#more-popover #ignore[type='submit'][form='transactions'][name='action'][value='ignore']"
             )
             |> LazyHTML.to_tree()

    assert [_] =
             LazyHTML.query(
               fragment,
               "#change-type[type='button'][phx-click='change-type'][phx-target='1']"
             )
             |> LazyHTML.to_tree()

    assert [_] =
             LazyHTML.query(
               fragment,
               "#edit-row[type='button'][phx-click='edit'][phx-value-id='123']"
             )
             |> LazyHTML.to_tree()
  end

  test "flash group presents one neutral reconnect state" do
    html = render_component(&flash_group/1, flash: %{})
    fragment = LazyHTML.from_fragment(html)
    reconnect = LazyHTML.query(fragment, "#connection-error")

    assert LazyHTML.text(reconnect) =~ "Connection lost"
    assert LazyHTML.text(reconnect) =~ "Reconnecting…"
    assert LazyHTML.attribute(reconnect, "phx-disconnected") != []
    assert LazyHTML.attribute(reconnect, "phx-connected") != []
    refute html =~ "client-error"
    refute html =~ "server-error"
    refute html =~ "find the internet"
    refute html =~ "Something went wrong"
  end

  test "flash group stacks compact notices and dismisses only from the close control" do
    html = render_component(&flash_group/1, flash: %{"info" => "Client updated."})
    fragment = LazyHTML.from_fragment(html)
    group = LazyHTML.query(fragment, "#flash-group.nila-flash-group[aria-live='polite']")
    notice = LazyHTML.query(group, "#flash-info.nila-toast")
    close = LazyHTML.query(notice, ".nila-alert-close[aria-label='Close notification']")

    assert LazyHTML.text(notice) =~ "Client updated."
    assert LazyHTML.attribute(notice, "phx-click") == []
    assert LazyHTML.attribute(close, "phx-click") != []
  end

  test "page_header renders eyebrow, display title, and intro copy" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_header eyebrow="Work Orders" title="Work Orders">
        Every project and LAMC visit.
      </.page_header>
      """)

    assert html =~ "Work Orders"
    assert html =~ "text-moon"
    assert html =~ "font-display"
    assert html =~ "Every project and LAMC visit."
  end

  test "page_header omits the eyebrow and intro when not given" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_header title="Work Orders" />
      """)

    assert html =~ "Work Orders"
    refute html =~ "text-moon"
  end

  test "stat_card renders label, value, and an optional value id" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.stat_card label="Work Orders shown" value_id="work-orders-count">42</.stat_card>
      """)

    assert html =~ "Work Orders shown"
    assert html =~ ~s(id="work-orders-count")
    assert html =~ "42"
    assert html =~ "nila-card"
    assert html =~ ~s(data-padding="compact")
    refute html =~ "rounded-box"
    refute html =~ "shadow-"
  end

  test "button exposes only controlled Radix-calibrated recipes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.button variant="soft" size="xs" full_width>Review</.button>
      """)

    assert html =~ ~s(class="nila-button w-full")
    assert html =~ ~s(data-variant="soft")
    assert html =~ ~s(data-size="xs")
    refute html =~ "btn-"
  end

  test "download button cannot navigate as an ordinary link" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.download_button href="/report.xml">Download report</.download_button>
      """)

    assert html =~ ~s(href="/report.xml")
    assert html =~ " download"
  end

  test "text link owns accent navigation color without raw primary classes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.text_link navigate="/privacy" class="font-medium">Privacy</.text_link>
      """)

    assert html =~ ~s(class="nila-link font-medium")
    assert html =~ ~s(href="/privacy")
    refute html =~ "text-primary"
  end

  test "compact callout keeps inline setup feedback dense" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.callout kind="warning" size="compact" title="Tally company not open">
        Open it in Tally.
      </.callout>
      """)

    assert html =~ ~s(class="nila-callout")
    assert html =~ ~s(data-kind="warning")
    assert html =~ ~s(data-size="compact")
    assert html =~ "Tally company not open"
  end

  test "spinner can request the closed accent tone" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.spinner tone="accent" label="Processing" />
      """)

    assert html =~ ~s(class="nila-spinner")
    assert html =~ ~s(data-tone="accent")
    assert html =~ "Processing"
  end

  test "segmented control owns filter geometry and selected state" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.segmented_control
        id="filters"
        items={[{:open, "Open"}, {:all, "All"}]}
        selected={:open}
        on_change="filter"
        value_name="scope"
      />
      """)

    assert html =~ "nila-segmented"
    assert html =~ ~s(phx-value-scope="open")
    assert html =~ ~s(aria-pressed="true")
  end

  test "standalone checkbox can expand its native label hit area" do
    html =
      render_component(&input/1,
        type: "checkbox",
        id: "select-row",
        name: "rows[]",
        checkbox_value: "42",
        checkbox_hit_area: "large",
        hidden_input: false,
        checked: true,
        disabled: true,
        "aria-label": "Select transaction"
      )

    fragment = LazyHTML.from_fragment(html)
    label = LazyHTML.query(fragment, "label[for='select-row'].nila-checkbox-target")
    checkbox = LazyHTML.query(label, "#select-row[type='checkbox']")
    assert LazyHTML.attribute(checkbox, "value") == ["42"]
    assert LazyHTML.attribute(checkbox, "aria-label") == ["Select transaction"]
    assert LazyHTML.attribute(checkbox, "checked") == [""]
    assert LazyHTML.attribute(checkbox, "disabled") == [""]
  end

  test "picker trigger owns Radix select-trigger anatomy" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.picker_trigger
        id="ledger-trigger"
        placeholder
        popovertarget="ledger-picker"
        disabled
      >
        Choose ledger
      </.picker_trigger>
      """)

    fragment = LazyHTML.from_fragment(html)
    trigger = LazyHTML.query(fragment, "#ledger-trigger")

    assert LazyHTML.attribute(trigger, "class") == ["nila-picker-trigger"]
    assert LazyHTML.attribute(trigger, "popovertarget") == ["ledger-picker"]
    assert LazyHTML.attribute(trigger, "data-placeholder") == [""]
    assert LazyHTML.attribute(trigger, "disabled") == [""]
    assert LazyHTML.query(trigger, ".nila-picker-trigger-inner")
    assert LazyHTML.query(trigger, ".nila-picker-trigger-icon")
  end

  test "select panel owns anchored searchable-list anatomy" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.select_panel id="ledger-picker" title="Choose ledger" filter_value="bank">
        <:search><input data-selectable-input /></:search>
        <.selectable_listbox id="ledger-options" label="Ledgers">
          <.selectable_option id="bank-charges">Bank Charges</.selectable_option>
        </.selectable_listbox>
      </.select_panel>
      """)

    assert html =~ ~s(id="ledger-picker")
    assert html =~ ~s(popover="auto")
    assert html =~ ~s(phx-hook="NilaWeb.Components.SelectableList.SelectPanelPopover")
    assert html =~ ~s(id="ledger-picker-navigation")
    assert html =~ ~s(phx-hook="SelectableList")
    assert html =~ ~s(data-filter-value="bank")
  end

  test "ledger picker keeps form truth in a hidden input and reuses the shared select panel" do
    assigns = %{
      form: to_form(%{"query" => "health"}, as: :ledger_picker),
      options: [{"Siemens Healthcare", "ledger:siemens"}]
    }

    html =
      rendered_to_string(~H"""
      <.ledger_picker_field
        id="party-ledger"
        name="posting[party_ledger]"
        label="Party ledger"
        prompt="Select party ledger"
        value="ledger:siemens"
        options={@options}
        picker="party"
        panel_id="ledger-picker"
        on_open="open-ledger-picker"
      />
      <.ledger_picker_panel
        id="ledger-picker"
        title="Tally party ledger"
        form={@form}
        options={@options}
        selected_identity="ledger:siemens"
        on_filter="filter-ledger-picker"
        on_submit="choose-first-ledger"
        on_select="choose-ledger"
        on_close="close-ledger-picker"
      />
      <.ledger_picker_shortcut id="choose-ledger" trigger_id="party-ledger">
        Choose ledger
      </.ledger_picker_shortcut>
      """)

    fragment = LazyHTML.from_fragment(html)
    trigger = LazyHTML.query(fragment, "#party-ledger")
    hidden = LazyHTML.query(fragment, "#party-ledger-value[type='hidden']")
    option = LazyHTML.query(fragment, "#ledger-picker-options [phx-click='choose-ledger']")

    assert LazyHTML.text(trigger) =~ "Siemens Healthcare"
    assert LazyHTML.attribute(trigger, "popovertarget") == ["ledger-picker"]
    assert LazyHTML.attribute(hidden, "name") == ["posting[party_ledger]"]
    assert LazyHTML.attribute(hidden, "value") == ["ledger:siemens"]
    assert LazyHTML.attribute(option, "phx-value-identity") == ["ledger:siemens"]
    assert LazyHTML.attribute(option, "aria-selected") == ["true"]
    assert html =~ ~s(data-on-close="close-ledger-picker")
    assert html =~ ~s(data-trigger-id="party-ledger")

    assert html =~
             ~s(phx-hook="NilaWeb.Components.LedgerPicker.LedgerPickerShortcut")

    assert html =~ ~s(id="ledger-picker-search-form")
    refute html =~ "<select"
  end

  test "selectable options keep selected and keyboard-active states distinct" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.selectable_listbox id="clients" label="Clients">
        <.selectable_option id="breeze" navigate="/clients/1" active>
          Breeze Tech
        </.selectable_option>
        <.selectable_option id="caltech" phx-click="close-clients" selected aria_current="page">
          Caltech
          <:meta>Current</:meta>
        </.selectable_option>
      </.selectable_listbox>
      """)

    fragment = LazyHTML.from_fragment(html)
    active = LazyHTML.query(fragment, "#breeze")
    selected = LazyHTML.query(fragment, "button#caltech")

    assert LazyHTML.attribute(active, "class") == ["nila-selectable-option"]
    assert LazyHTML.attribute(active, "href") == ["/clients/1"]
    assert LazyHTML.attribute(active, "data-active") == [""]
    assert LazyHTML.attribute(active, "aria-selected") == ["false"]
    assert LazyHTML.attribute(selected, "type") == ["button"]
    assert LazyHTML.attribute(selected, "phx-click") == ["close-clients"]
    assert LazyHTML.attribute(selected, "href") == []
    assert LazyHTML.attribute(selected, "data-state") == ["selected"]
    assert LazyHTML.attribute(selected, "aria-selected") == ["true"]
    assert LazyHTML.attribute(selected, "aria-current") == ["page"]
  end

  test "table modes own geometry and require a semantic row header" do
    assigns = %{rows: [%{invoice: "INV-1", status: "Reviewed"}]}

    html =
      rendered_to_string(~H"""
      <div>
        <.data_table id="scan-table" rows={@rows} mode="scan">
          <:col :let={row} label="Invoice" row_header>{row.invoice}</:col>
        </.data_table>
        <.data_table id="worklist-table" rows={@rows} mode="worklist">
          <:col :let={row} label="Invoice" row_header>{row.invoice}</:col>
        </.data_table>
        <.data_table id="review-table" rows={@rows} mode="review">
          <:col :let={row} label="Invoice" row_header>{row.invoice}</:col>
        </.data_table>
      </div>
      """)

    assert html =~ ~s(data-mode="scan")
    assert html =~ ~s(data-mode="worklist")
    assert html =~ ~s(data-mode="review")
    assert html =~ ~s(<th scope="row" class="text-left">)
    assert html =~ "INV-1"
    refute html =~ "px-3 py-2"
    refute html =~ "px-4 py-3"
  end

  test "table toolbar is attached inside the table surface" do
    assigns = %{rows: [%{invoice: "INV-1"}]}

    html =
      rendered_to_string(~H"""
      <.data_table id="selectable-table" rows={@rows} mode="scan">
        <:toolbar>
          <div id="selection-tools">1 selected</div>
        </:toolbar>
        <:col :let={row} label="Invoice" row_header>{row.invoice}</:col>
      </.data_table>
      """)

    fragment = LazyHTML.from_fragment(html)

    assert LazyHTML.query(fragment, ".nila-table-shell > .nila-table-toolbar #selection-tools")
    assert LazyHTML.query(fragment, ".nila-table-shell > .nila-table-scroll table")
  end

  test "table supports an interactive keyed column header" do
    assigns = %{rows: [%{invoice: "INV-1"}]}

    html =
      rendered_to_string(~H"""
      <.data_table id="selectable-table" rows={@rows} mode="scan">
        <:col_header column="selection">
          <button id="select-all" type="button">Select all</button>
        </:col_header>
        <:col :let={row} key="selection" label="Select">{row.invoice}</:col>
        <:col :let={row} label="Invoice" row_header>{row.invoice}</:col>
      </.data_table>
      """)

    assert html =~ ~s(id="select-all")
    assert html =~ "Select all"
    refute html =~ ">Select</th>"
  end

  test "table rejects ambiguous row-header semantics" do
    assigns = %{rows: [%{invoice: "INV-1"}]}

    assert_raise ArgumentError, ~r/exactly one :col with row_header/, fn ->
      rendered_to_string(~H"""
      <.data_table id="missing-row-header" rows={@rows} mode="scan">
        <:col :let={row} label="Invoice">{row.invoice}</:col>
      </.data_table>
      """)
    end
  end

  test "input family uses the canonical field recipes" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <div>
        <.input id="invoice" name="invoice" label="Invoice" value="INV-1" />
        <.input
          type="select"
          id="state"
          name="state"
          label="State"
          value="Gujarat"
          options={["Gujarat"]}
        />
        <.input type="checkbox" id="reviewed" name="reviewed" label="Reviewed" value={true} />
      </div>
      """)

    assert html =~ "nila-field-label"
    assert html =~ "nila-input"
    assert html =~ "nila-select"
    assert html =~ "nila-checkbox"
    refute html =~ ~s(class="input)
    refute html =~ ~s(class="select)
  end

  test "checkbox supports collection values without a hidden false input" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input
        type="checkbox"
        id="transaction-42"
        name="transaction_ids[]"
        checkbox_value="42"
        hidden_input={false}
        checked
      />
      """)

    fragment = LazyHTML.from_fragment(html)
    checkbox = LazyHTML.query(fragment, "#transaction-42")

    assert LazyHTML.attribute(checkbox, "value") == ["42"]
    assert LazyHTML.attribute(checkbox, "checked") == [""]
    refute html =~ ~s(type="hidden")
  end

  test "number inputs render server numeric values without exponent notation" do
    assigns = %{float: 3_000.0, decimal: Decimal.new("3.0e3")}

    html =
      rendered_to_string(~H"""
      <div>
        <.input type="number" id="float-amount" name="float_amount" value={@float} />
        <.input type="number" id="decimal-amount" name="decimal_amount" value={@decimal} />
      </div>
      """)

    fragment = LazyHTML.from_fragment(html)

    assert fragment |> LazyHTML.query("#float-amount") |> LazyHTML.attribute("value") == ["3000"]

    assert fragment |> LazyHTML.query("#decimal-amount") |> LazyHTML.attribute("value") == [
             "3000"
           ]
  end

  test "badge renders a soft pill in the given semantic variant" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.badge variant="success">Completed</.badge>
      """)

    assert html =~ ~s(class="nila-badge")
    assert html =~ ~s(data-variant="success")
    refute html =~ "badge-soft"
    refute html =~ "text-context"
    assert html =~ "Completed"
  end

  test "account menu uses the native light-dismiss popover contract" do
    assigns = %{
      current_scope: %{user: %{name: "Dev Owner"}, current_org: %{name: "Nila CA"}}
    }

    html =
      rendered_to_string(~H"""
      <.account_menu current_scope={@current_scope} placement={:rail} id_prefix="test" />
      """)

    assert html =~ ~s(<button)
    assert html =~ ~s(popovertarget="test-account-popover")
    assert html =~ ~s(id="test-account-popover")
    assert html =~ ~s(popover="auto")
    refute html =~ "<details"
    refute html =~ "<summary"
  end

  test "context text owns the restricted 12px role" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.context_text tag="p" tone="muted" weight="medium" id="upload-context">
        Uploaded 12 minutes ago
      </.context_text>
      """)

    assert html =~ ~s(id="upload-context")
    assert html =~ ~s(class="text-context text-ink-muted font-medium")
    assert html =~ "Uploaded 12 minutes ago"
  end

  test "fold summary keeps operational detail at the working size" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.fold_summary title="Party-wise B2B working" tabular>
        <:detail>4 recipients · ₹1,28,230.74 output tax</:detail>
        <:status>
          <.badge variant="neutral">Inspect</.badge>
        </:status>
      </.fold_summary>
      """)

    assert html =~ "Party-wise B2B working"
    assert html =~ "text-ink-muted text-ui tabular-nums"
    refute html =~ "text-context"
  end
end
