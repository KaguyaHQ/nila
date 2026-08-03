defmodule NilaWeb.Components.ModalTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import NilaWeb.Components.Modal

  test "ordinary modal closes on click-away and Escape" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.modal id="invoice-modal" title="Invoice" on_close="close-invoice">
        Invoice details
      </.modal>
      """)

    focus_wrap =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#invoice-modal-focus-wrap")

    assert LazyHTML.attribute(focus_wrap, "phx-click-away") == ["close-invoice"]
    assert LazyHTML.attribute(focus_wrap, "phx-window-keydown") == ["close-invoice"]
    assert LazyHTML.attribute(focus_wrap, "phx-key") == ["escape"]
    assert html =~ "max-h-[90vh]"
    assert html =~ "max-w-lg"
    assert html =~ "Invoice details"
  end

  test "workbench fills the viewport and only uses its explicit close affordance" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.modal
        id="review-workbench"
        title="Review invoice"
        on_close="finish-review"
        variant="workbench"
        close_label="Done"
        close_on_escape={false}
      >
        Review surface
      </.modal>
      """)

    fragment = LazyHTML.from_fragment(html)
    focus_wrap = LazyHTML.query(fragment, "#review-workbench-focus-wrap")

    assert LazyHTML.attribute(focus_wrap, "phx-click-away") == []
    assert LazyHTML.attribute(focus_wrap, "phx-window-keydown") == []
    assert LazyHTML.attribute(focus_wrap, "phx-key") == []
    assert html =~ "h-dvh"
    assert html =~ "max-h-none"
    assert html =~ "max-w-none"
    refute html =~ "max-h-[90vh]"

    assert fragment
           |> LazyHTML.query("#review-workbench-focus-wrap button[phx-click='finish-review']")
           |> LazyHTML.text() =~ "Done"
  end

  test "workbench body retains the scrolling contract" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.modal id="review-workbench" title="Review" on_close="done" variant="workbench">
        Review surface
      </.modal>
      """)

    body =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#review-workbench-focus-wrap > div")

    assert LazyHTML.attribute(body, "class") == ["min-h-0 flex-1 overflow-y-auto"]
  end
end
