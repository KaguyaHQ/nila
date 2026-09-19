defmodule NilaWeb.ClientImportTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Nila.Clients

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    %{conn: log_in_user(conn, user), org: org}
  end

  test "Excel upload previews skipped rows and adds clients only after confirmation", %{
    conn: conn,
    org: org
  } do
    {:ok, bytes} =
      XlsxWriter.generate([
        XlsxWriter.new_sheet("Clients")
        |> XlsxWriter.write(0, 0, "Client name")
        |> XlsxWriter.write(0, 1, "GSTIN")
        |> XlsxWriter.write(0, 2, "GST username")
        |> XlsxWriter.write(1, 0, "Breeze Tech")
        |> XlsxWriter.write(1, 1, "33AEWPH4158J1Z3")
        |> XlsxWriter.write(1, 2, " breeze_2017 ")
        |> XlsxWriter.write(2, 0, "Bad row")
        |> XlsxWriter.write(2, 1, "INVALID")
      ])

    {:ok, view, _} = live(conn, ~p"/clients")
    view |> element("#clients-import") |> render_click()

    upload =
      file_input(view, "#clients-import-form", :client_excel, [
        %{
          name: "clients.xlsx",
          content: bytes,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(upload, "clients.xlsx", 100)
    view |> form("#clients-import-form") |> render_submit()
    assert has_element?(view, "#clients-import-summary", "1 client ready to add")
    assert has_element?(view, "#clients-import-preview", "GSTIN is invalid")
    assert has_element?(view, "#clients-import-preview", "breeze_2017")
    assert Clients.list_clients(org.id) == []
    view |> element("#clients-import-save") |> render_click()
    assert has_element?(view, "#clients-import-modal-title", "1 client added")
    assert has_element?(view, "#clients-import-summary", "1 row skipped")
    assert has_element?(view, "#clients-import-preview .hero-check-circle-solid")
    assert has_element?(view, "#clients-table", "Breeze Tech")
    refute has_element?(view, "#clients-table", "Bad row")
    render_click(view, "save-import")
    assert length(Clients.list_clients(org.id)) == 1
    view |> element("#clients-import-close") |> render_click()
    refute has_element?(view, "#clients-import-modal")
    [client] = Clients.list_clients(org.id)
    assert client.gst_username == "breeze_2017"
    assert {:error, :not_found} = Nila.Gst.Portal.connection(org.id, client.id)
    {:ok, edit, _} = live(conn, ~p"/clients/#{client.id}/edit")
    edit |> element("#client-gst-connect") |> render_click()
    assert has_element?(edit, "#gst-username[value='breeze_2017']")
  end

  test "template is downloadable and viewer cannot open import", %{conn: conn, org: org} do
    response = get(conn, ~p"/clients/import-template.xlsx")
    assert response(response, 200) =~ "PK"
    viewer = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, viewer.id, "viewer")
    {:ok, view, _} = live(log_in_user(build_conn(), viewer), ~p"/clients")
    assert has_element?(view, "#clients-import[disabled]")
    render_click(view, "open-import")
    refute has_element?(view, "#clients-import-modal")
  end
end
