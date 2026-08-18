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
    assert html =~ ~s(class="nila-modal-panel")
    assert html =~ ~s(data-variant="modal")
    assert html =~ ~s(data-width="standard")
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
    assert html =~ ~s(class="nila-modal-panel")
    assert html =~ ~s(data-variant="workbench")
    refute html =~ "max-h-[90vh]"

    assert fragment
           |> LazyHTML.query("#review-workbench-focus-wrap button[phx-click='finish-review']")
           |> LazyHTML.text() =~ "Done"
  end

  test "sheet retains ordinary dialog dismissal and declares edge geometry" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.modal
        id="client-sheet"
        title="Switch client"
        on_close="close-sheet"
        variant="sheet"
        side="left"
        return_focus="#open-client-switcher"
      >
        Client list
        <:footer>Sheet actions</:footer>
      </.modal>
      """)

    fragment = LazyHTML.from_fragment(html)
    scrim = LazyHTML.query(fragment, "#client-sheet")
    focus_wrap = LazyHTML.query(fragment, "#client-sheet-focus-wrap")

    assert LazyHTML.attribute(scrim, "data-variant") == ["sheet"]
    assert LazyHTML.attribute(scrim, "data-side") == ["left"]
    assert LazyHTML.attribute(scrim, "phx-remove") != []
    assert LazyHTML.attribute(focus_wrap, "data-variant") == ["sheet"]
    assert LazyHTML.attribute(focus_wrap, "data-side") == ["left"]
    assert LazyHTML.attribute(focus_wrap, "phx-click-away") == ["close-sheet"]
    assert LazyHTML.attribute(focus_wrap, "phx-window-keydown") == ["close-sheet"]
    assert LazyHTML.attribute(focus_wrap, "phx-key") == ["escape"]

    assert LazyHTML.attribute(
             LazyHTML.query(fragment, "#client-sheet-focus-wrap > .nila-modal-body"),
             "class"
           ) == [
             "nila-modal-body min-h-0 flex-1 overflow-y-auto"
           ]

    assert fragment
           |> LazyHTML.query("#client-sheet-focus-wrap > .nila-modal-footer")
           |> LazyHTML.text() =~ "Sheet actions"
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

    assert LazyHTML.attribute(body, "class") == [
             "nila-modal-body min-h-0 flex-1 overflow-y-auto"
           ]
  end
end
