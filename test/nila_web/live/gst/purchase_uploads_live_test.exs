defmodule NilaWeb.Gst.PurchaseUploadsLiveTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Nila.Gst.Intake.Dumps

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Upload QA",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{conn: log_in_user(conn, user), org: org, client: client, user: user}
  end

  test "overview opens empty history and month navigation stays in uploads", c do
    base = "/gst/#{c.client.id}/2026-08/purchases"
    assert c.conn |> get(base) |> redirected_to() == "/app" <> base
    {:ok, view, _} = live(c.conn, base <> "/uploads")
    assert has_element?(view, "#purchase-uploads-empty")
    assert has_element?(view, "#previous-filing-period[href*='/2026-07/purchases/uploads']")
  end

  test "history preserves source, excluded rows and exact batch invoices", c do
    invoice = %{
      "invoice_number" => "ONLY-THIS-UPLOAD",
      "taxable_paise" => 123_456,
      "tax_paise" => %{"igst" => 18000}
    }

    dump =
      record(c, %{
        status: "extracted",
        invoices: [invoice],
        file_keys: ["original.xlsx"],
        meta: %{
          "original_name" => "August purchases.xlsx",
          "excel_sheet" => "Purchases",
          "excel_excluded_rows" => [4, 9],
          "excel_other_sheets" => ["Summary"]
        }
      })

    record(c, %{
      status: "failed",
      error: "Could not read the workbook",
      meta: %{"original_name" => "broken.xlsx"}
    })

    record(c, %{kind: "sales", meta: %{"original_name" => "sales-secret.xlsx"}})
    {:ok, view, _} = live(c.conn, "/gst/#{c.client.id}/2026-08/purchases/uploads")
    assert has_element?(view, "#purchase-uploads", "August purchases.xlsx")


    assert has_element?(view, "#purchase-uploads", "1 invoice imported")
    assert has_element?(view, "#purchase-uploads", "Could not read the workbook")
    assert has_element?(view, "#purchase-upload-excluded-#{dump.id}", "rows 4, 9")
    assert has_element?(view, "a[href='/gst/#{c.client.id}/2026-08/original/#{dump.id}/0']")
    refute has_element?(view, "#purchase-uploads", "sales-secret.xlsx")
    view |> element("#purchase-upload-open-#{dump.id}") |> render_click()
    assert has_element?(view, "#purchase-upload-invoices", "ONLY-THIS-UPLOAD")
    assert has_element?(view, "#purchase-upload-invoices", "1,234.56")
    assert has_element?(view, "#purchase-upload-invoices", "180.00")
    view |> element("#purchase-upload-back") |> render_click()
    assert has_element?(view, "#purchase-uploads", "August purchases.xlsx")
  end

  test "upload query cannot expose another month or organisation", c do
    foreign = record(c, %{period: "2026-07", invoices: [%{"invoice_number" => "PRIVATE"}]})

    {:ok, view, _} =
      live(c.conn, "/gst/#{c.client.id}/2026-08/purchases/uploads?upload=#{foreign.id}")

    assert has_element?(view, "#purchase-upload-unavailable")
    refute has_element?(view, "#purchase-upload-detail")
    %{user: other} = user_with_org_fixture()
    conn = build_conn() |> log_in_user(other)

    assert {:error, {:live_redirect, %{to: "/app/clients"}}} =
             live(conn, "/gst/#{c.client.id}/2026-08/purchases/uploads")
  end

  test "processing result refreshes when worker finishes", c do
    dump = record(c, %{status: "extracting"})
    {:ok, view, _} = live(c.conn, "/gst/#{c.client.id}/2026-08/purchases/uploads")
    assert has_element?(view, "#purchase-uploads", "Processing")

    dump
    |> Nila.Gst.Intake.Dump.changeset(%{
      status: "extracted",
      invoices: [%{"invoice_number" => "DONE"}]
    })
    |> Nila.Repo.update!()

    send(view.pid, {:gst_dump_progress, c.org.id, c.client.id, "2026-08", dump.id, "extracted"})
    assert has_element?(view, "#purchase-uploads", "1 invoice imported")
  end

  defp record(c, attrs) do
    {:ok, dump} =
      Dumps.record(
        %{org_id: c.org.id, client_id: c.client.id, brought_in_by_id: c.user.id},
        Map.merge(
          %{kind: "purchase", period: "2026-08", status: "received", file_keys: []},
          attrs
        )
      )

    dump
  end
end
