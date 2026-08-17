defmodule NilaWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import NilaWeb.Components.Page
  import NilaWeb.Components.Card
  import NilaWeb.Components.Badge
  import NilaWeb.Components.Button
  import NilaWeb.Components.Input
  import NilaWeb.Components.Fold
  import NilaWeb.Components.Typography

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
    assert html =~ "border-base-300"
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
