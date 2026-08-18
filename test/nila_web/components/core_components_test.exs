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

  test "table density is owned by the controlled data attribute" do
    assigns = %{rows: [%{invoice: "INV-1", status: "Reviewed"}]}

    html =
      rendered_to_string(~H"""
      <div>
        <.data_table id="standard-table" rows={@rows}>
          <:col :let={row} label="Invoice">{row.invoice}</:col>
        </.data_table>
        <.data_table id="dense-table" rows={@rows} dense>
          <:col :let={row} label="Invoice">{row.invoice}</:col>
        </.data_table>
      </div>
      """)

    assert html =~ ~s(data-density="standard")
    assert html =~ ~s(data-density="dense")
    refute html =~ "px-3 py-2"
    refute html =~ "px-4 py-3"
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
