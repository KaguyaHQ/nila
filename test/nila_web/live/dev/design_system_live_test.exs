defmodule NilaWeb.Dev.DesignSystemLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the executable reference from real components", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    assert has_element?(view, "#design-system-reference")
    assert has_element?(view, "#ds-typography #ds-type-context")

    assert has_element?(
             view,
             "#ds-buttons .nila-button[data-variant='primary']",
             "Approve GSTR-1"
           )

    assert has_element?(view, "#ds-buttons .nila-button[data-size='xs']", "Compact")
    assert has_element?(view, "#ds-buttons .nila-button[data-size='sm']", "Standard")
    assert has_element?(view, "#ds-buttons .nila-button[data-size='lg']", "Prominent")
    assert has_element?(view, "#ds-segmented button[aria-pressed='true']", "Needs you")

    for {variant, label} <- [
          {"info", "Proposed"},
          {"success", "Reviewed"},
          {"warning", "Needs review"},
          {"error", "Blocked"}
        ] do
      assert has_element?(view, "#ds-colors .nila-status-swatch[data-kind='#{variant}']")
      assert has_element?(view, "#ds-badges .nila-badge[data-variant='#{variant}']", label)
      assert has_element?(view, "#ds-feedback .nila-callout[data-kind='#{variant}']")
    end

    assert has_element?(view, "#ds-fields .nila-input")
    assert has_element?(view, "#ds-fields .nila-select")

    assert has_element?(
             view,
             "#ds-selectable-list #ds-selectable-breeze[data-active][aria-selected='false']"
           )

    assert has_element?(
             view,
             "#ds-selectable-list #ds-selectable-caltech[data-state='selected'][aria-selected='true']",
             "Current"
           )

    assert has_element?(view, "#ds-cards", "₹39,520.80")
    assert has_element?(view, "#ds-register-rows tr", "INV-1048")
    assert has_element?(view, "#ds-workpaper-result", "Draft prepared. One invoice needs you.")
    assert has_element?(view, "#ds-b2b-schedule[open]")
  end

  test "segmented control keeps selection in the controlled LiveView assign", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    view |> element("#ds-segmented button", "All") |> render_click()

    assert has_element?(view, "#ds-segmented button[aria-pressed='true']", "All")
    assert has_element?(view, "#ds-segmented button[aria-pressed='false']", "Needs you")
  end

  test "modal example uses the real LiveView dismissal contract", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    view |> element("#ds-open-modal") |> render_click()

    assert has_element?(view, "#ds-modal .nila-modal-panel[data-width='standard']")

    view
    |> element("#ds-modal-confirm")
    |> render_click()

    refute has_element?(view, "#ds-modal")
  end

  test "sheet example uses the shared edge, anatomy, and dismissal contract", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    view |> element("#ds-open-sheet") |> render_click()

    assert has_element?(
             view,
             "#ds-sheet[data-side='right'] .nila-modal-panel[data-variant='sheet']",
             "Sheet title"
           )

    assert has_element?(view, "#ds-sheet .nila-modal-footer", "Done")

    view
    |> element("#ds-sheet button[phx-click='close-design-sheet']", "Done")
    |> render_click()

    refute has_element?(view, "#ds-sheet")
  end

  test "fold examples preserve server-owned open state", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    view
    |> element("#ds-rate-summary > summary")
    |> render_click()

    assert has_element?(view, "#ds-rate-summary[open]")

    view
    |> element("#ds-rate-summary > summary")
    |> render_click()

    refute has_element?(view, "#ds-rate-summary[open]")
  end
end
