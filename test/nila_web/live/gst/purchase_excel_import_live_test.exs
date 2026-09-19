defmodule NilaWeb.Gst.PurchaseExcelImportLiveTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Nila.Gst.Intake.{Dumps, DumpWorker}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase import",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{conn: log_in_user(conn, user), client: client, org: org}
  end

  defp upload(view) do
    bytes = File.read!("test/fixtures/purchase_excel/standard.xlsx")

    input =
      file_input(view, "#purchase-excel-upload", :excel, [
        %{
          name: "purchases.xlsx",
          content: bytes,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(input, "purchases.xlsx", 100)
    view |> form("#purchase-excel-upload") |> render_submit()
  end

  test "map, preview and confirm purchases into the new queue", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/purchases/import-excel")
    upload(view)
    assert has_element?(view, "#purchase-excel-column-C", "Example local supplier")
    view |> form("#purchase-excel-mapping") |> render_submit()
    assert has_element?(view, "#purchase-excel-summary", "2 invoices")
    assert has_element?(view, "#purchase-excel-totals", "4,000.00")
    refute has_element?(view, "#purchase-excel-save[disabled]")
    view |> element("#purchase-excel-save") |> render_click()
    assert_redirect(view, ~p"/gst/#{client.id}/2026-08/purchases")
    [dump] = Dumps.list(org.id, client.id, "2026-08")
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    {:ok, queue, _} = live(conn, ~p"/gst/#{client.id}/2026-08/purchases")
    assert has_element?(queue, "a", "DEMO-001")
  end

  test "editing mapping invalidates preview and missing GSTIN prevents import", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/purchases/import-excel")
    upload(view)
    view |> form("#purchase-excel-mapping") |> render_submit()
    view |> element("#purchase-excel-edit-mapping") |> render_click()
    view |> form("#purchase-excel-mapping", columns: %{D: ""}) |> render_change()
    refute has_element?(view, "#purchase-excel-save")
    assert has_element?(view, "#purchase-excel-preview[disabled]")
    assert has_element?(view, "#purchase-excel-mapping-needs", "Supplier GSTIN")
  end
end
