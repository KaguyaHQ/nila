defmodule NilaWeb.RetiredLiveviewTest do
  use NilaWeb.ConnCase, async: true

  test "product routes contain no LiveView handlers" do
    routes = Phoenix.Router.routes(NilaWeb.Router)
    refute Enum.any?(routes, &(&1.plug == Phoenix.LiveView.Plug))
    refute :phoenix_live_view in Application.spec(:nila, :applications)
  end

  test "retired screens have no routes" do
    for path <- [
          "/today",
          "/register",
          "/banking",
          "/banking/new",
          "/banking/1",
          "/gst/upload",
          "/gst/1/2026-06",
          "/gst/1/2026-06/sales",
          "/gst/1/2026-06/sales/invoices/source-1",
          "/gst/1/2026-06/review/sales",
          "/gst/1/2026-06/import-excel",
          "/gst/1/2026-06/purchases/import-excel",
          "/gst/1/2026-06/purchases/uploads",
          "/sales-bills/1/batch/1",
          "/settings/connectors",
          "/settings/connectors/tally/pair/code",
          "/dev/design-system",
          "/dev/dashboard"
        ] do
      assert Phoenix.Router.route_info(NilaWeb.Router, "GET", path, "localhost") == :error,
             "Unexpected retained route: #{path}"
    end
  end

  test "public pages use static links and HTTP flash", %{conn: conn} do
    html = conn |> get("/india/contact") |> html_response(200)
    refute html =~ "data-phx-session"
    refute html =~ "data-phx-link"
    refute html =~ "phx-hook"
    assert html =~ "action=\"/contact/callback\""
  end
end
