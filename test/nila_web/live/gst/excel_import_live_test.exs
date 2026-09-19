defmodule NilaWeb.Gst.ExcelImportLiveTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Nila.Gst.Intake.{DumpWorker, Dumps}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Excel UI",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{conn: log_in_user(conn, user), org: org, client: client}
  end

  defp upload(view, name) do
    bytes = File.read!("test/fixtures/sales_excel/#{name}.xlsx")

    input =
      file_input(view, "#sales-excel-upload", :excel, [
        %{
          name: name <> ".xlsx",
          content: bytes,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(input, name <> ".xlsx", 100)
    view |> form("#sales-excel-upload") |> render_submit()
  end

  test "upload, review exclusions, confirm, review source and download workings", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/import-excel")
    upload(view, "subtotals")
    assert has_element?(view, "#sales-excel-column-A", "DEMO-001")
    assert has_element?(view, "#sales-excel-column-B", "05-08-2026")
    refute has_element?(view, "#sales-excel-column-A", "Grand total")
    assert has_element?(view, "#sales-excel-exclude-10[checked]")
    view |> form("#sales-excel-mapping") |> render_submit()

    assert has_element?(
             view,
             "#sales-excel-summary",
             "2 invoices · 3 source rows · 1 row left out"
           )

    assert has_element?(view, "#sales-excel-totals", "4,000.00")
    refute has_element?(view, "#sales-excel-save[disabled]")
    assert Dumps.list(org.id, client.id, "2026-08") == []
    view |> element("#sales-excel-save") |> render_click()
    assert_redirect(view, ~p"/gst/#{client.id}/2026-08/sales")
    [dump] = Dumps.list(org.id, client.id, "2026-08")
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    invoice = hd(dump.invoices)
    {:ok, review, _} = live(conn, ~p"/gst/#{client.id}/2026-08/sales/invoices/#{invoice["id"]}")
    assert has_element?(review, "#sales-bill-excel-source", "August sales")
    assert has_element?(review, "#sales-bill-download-excel")
    exported = conn |> get(~p"/gstr1/#{client.id}/2026-08/workings.xlsx") |> response(200)
    assert {:ok, files} = :zip.extract(exported, [:memory])

    assert Enum.any?(files, fn {_, bytes} ->
             String.contains?(bytes, "subtotals.xlsx / August sales / rows 7")
           end)
  end

  test "changing mapping invalidates the old preview", %{conn: conn, client: client} do
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/import-excel")
    upload(view, "standard")
    view |> form("#sales-excel-mapping") |> render_submit()
    assert has_element?(view, "#sales-excel-save")
    view |> element("#sales-excel-edit-mapping") |> render_click()
    view |> form("#sales-excel-mapping", columns: %{A: ""}) |> render_change()
    refute has_element?(view, "#sales-excel-save")
    assert has_element?(view, "#sales-excel-mapping-needs", "Choose columns for: Invoice number")
    assert has_element?(view, "#sales-excel-preview[disabled]")
    view |> form("#sales-excel-mapping") |> render_submit()
    assert has_element?(view, "#sales-excel-error", "Invoice number")
  end

  test "template downloads and viewers cannot import", %{conn: conn, org: org, client: client} do
    assert conn |> get(~p"/gst/sales-template.xlsx") |> response(200) |> String.starts_with?("PK")
    viewer = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, viewer.id, "viewer")

    assert {:error, {:live_redirect, %{to: "/clients"}}} =
             live(log_in_user(build_conn(), viewer), ~p"/gst/#{client.id}/2026-08/import-excel")
  end

  test "duplicate field choices block preview without losing either choice", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/import-excel")
    upload(view, "standard")
    view |> form("#sales-excel-mapping", columns: %{C: "invoice_number"}) |> render_change()

    assert has_element?(
             view,
             "#sales-excel-mapping-needs",
             "Invoice number is selected for more than one column"
           )

    assert has_element?(view, "#columns_A option[selected][value='invoice_number']")
    assert has_element?(view, "#columns_C option[selected][value='invoice_number']")
    view |> form("#sales-excel-mapping") |> render_submit()
    refute has_element?(view, "#sales-excel-save")
    view |> form("#sales-excel-mapping", columns: %{C: "buyer_name"}) |> render_change()
    refute has_element?(view, "#sales-excel-preview[disabled]")
    view |> form("#sales-excel-mapping") |> render_submit()
    assert has_element?(view, "#sales-excel-summary", "2 invoices")
  end

  test "unfamiliar columns stay visible beside samples and can be mapped manually", %{
    conn: conn,
    client: client
  } do
    bytes = File.read!("test/fixtures/sales_excel/standard.xlsx")
    {:ok, files} = :zip.extract(bytes, [:memory])

    files =
      Enum.map(files, fn {path, data} ->
        {path,
         data
         |> String.replace("GST rate", "RATE")
         |> String.replace("Item description", "Staff notes")}
      end)

    {:ok, {_, bytes}} = :zip.create(~c"unfamiliar.xlsx", files, [:memory])
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/2026-08/import-excel")

    input =
      file_input(view, "#sales-excel-upload", :excel, [
        %{
          name: "unfamiliar.xlsx",
          content: bytes,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(input, "unfamiliar.xlsx", 100)
    view |> form("#sales-excel-upload") |> render_submit()
    assert has_element?(view, "#sales-excel-column-I", "RATE")
    assert has_element?(view, "#sales-excel-column-I", "18")
    refute has_element?(view, "#columns_I option[value='gst_rate'][selected]")
    assert has_element?(view, "#sales-excel-column-G", "Staff notes")
    assert has_element?(view, "#sales-excel-column-G", "Repair service")
    assert has_element?(view, "#sales-excel-mapping-needs", "GST rate (%)")
    view |> form("#sales-excel-mapping", columns: %{I: "gst_rate"}) |> render_change()
    refute has_element?(view, "#sales-excel-preview[disabled]")
    view |> form("#sales-excel-mapping") |> render_submit()
    assert has_element?(view, "#sales-excel-summary", "2 invoices")
  end
end
