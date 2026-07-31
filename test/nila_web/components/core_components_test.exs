defmodule NilaWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import NilaWeb.Components.Page
  import NilaWeb.Components.Card
  import NilaWeb.Components.Badge

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

  test "badge renders a soft pill in the given semantic variant" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.badge variant="success">Completed</.badge>
      """)

    assert html =~ "badge-soft"
    assert html =~ "badge-success"
    assert html =~ "Completed"
  end
end
