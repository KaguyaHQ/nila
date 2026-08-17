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

    assert has_element?(view, "#ds-badges .nila-badge[data-variant='warning']", "Needs review")
    assert has_element?(view, "#ds-fields .nila-input")
    assert has_element?(view, "#ds-fields .nila-select")
    assert has_element?(view, "#ds-feedback .nila-callout[data-kind='warning']")
    assert has_element?(view, "#ds-cards", "₹39,520.80")
    assert has_element?(view, "#ds-register-rows tr", "INV-1048")
    assert has_element?(view, "#ds-workpaper-result", "Draft prepared. One invoice needs you.")
    assert has_element?(view, "#ds-b2b-schedule[open]")
  end

  test "modal example uses the real LiveView dismissal contract", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, NilaWeb.Dev.DesignSystemLive)

    view |> element("#ds-open-modal") |> render_click()

    assert has_element?(view, "#ds-modal .nila-modal-panel[data-width='standard']")

    view
    |> element("#ds-modal button[phx-click='close-design-modal']", "Confirm review")
    |> render_click()

    refute has_element?(view, "#ds-modal")
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
