defmodule NilaWeb.LegacyWorkspaceControllerTest do
  use NilaWeb.ConnCase, async: true

  test "old workspace URLs enter React and preserve the requested record and search", %{
    conn: conn
  } do
    %{user: user} = user_with_org_fixture()
    conn = log_in_user(conn, user)

    for path <- [
          "/clients",
          "/clients/new",
          "/clients/12/edit",
          "/notices",
          "/notices/4",
          "/settings/profile",
          "/settings/security",
          "/settings/workspace",
          "/settings/users",
          "/gst/12/2026-06/purchases"
        ] do
      assert conn |> get(path <> "?q=ABC&filter=all") |> redirected_to() ==
               "/app" <> path <> "?q=ABC&filter=all"
    end

    assert conn
           |> get("/gst/12/2026-06/purchases/invoices/g2b-4?filter=itc&q=ABC")
           |> redirected_to() ==
             "/app/gst/12/2026-06/purchases/review/g2b-4?filter=itc&q=ABC"

    assert conn |> get("/gst/2b?client_id=12&period=2026-06") |> redirected_to() ==
             "/app/gst/12/2026-06/purchases?client_id=12&period=2026-06"

    assert conn
           |> get("/gst/12/2026-06/purchases/register?filter=gstr2b&q=ABC")
           |> redirected_to() == "/app/gst/12/2026-06/purchases/register?q=ABC&source=gstr2b"

    assert conn |> get("/gst/12/2026-06/purchases/register?filter=itc") |> redirected_to() ==
             "/app/gst/12/2026-06/purchases/review?filter=itc"

    assert conn |> get("/gst/2b") |> redirected_to() == "/app/clients"
  end

  test "legacy routes retain sign-in and verification gates", %{conn: conn} do
    assert conn |> get("/clients") |> redirected_to() == "/users/log_in"
    %{user: user} = user_with_org_fixture()
    user = user |> Ecto.Changeset.change(confirmed_at: nil) |> Nila.Repo.update!()

    assert conn |> log_in_user(user) |> get("/settings/profile") |> redirected_to() ==
             "/users/confirm"
  end

  test "retained imports, GSTR-3B and connectors remain LiveViews" do
    for path <- [
          "/gst/:client_id/:period/import-excel",
          "/gst/:client_id/:period/purchases/import-excel",
          "/gst/:client_id/:period/purchases/uploads",
          "/gst/:client_id/:period/gstr3b",
          "/settings/connectors"
        ] do
      route = Enum.find(NilaWeb.Router.__routes__(), &(&1.path == path))
      assert route.metadata[:phoenix_live_view]
    end
  end
end
