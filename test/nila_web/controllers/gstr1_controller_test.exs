defmodule NilaWeb.Gstr1ControllerTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Clients
  alias Nila.Gst.Sales.{Gstr1, Months}
  alias Nila.Repo
  alias Nila.TallyJobs.Job

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze & Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    invoice =
      Normalizer.normalize(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "29",
          "invoice_number" => "INV-001",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Customer & Co", "gstin" => "29AAVCS8021P1ZB"},
          "line_items" => [
            %{
              "description" => "Technical support services",
              "hsn_sac" => "998719",
              "printed_taxable_value" => 1000,
              "igst_rate" => 18,
              "igst_amount" => 180
            }
          ],
          "printed_total_taxable" => 1000,
          "printed_total_tax" => 180,
          "printed_grand_total" => 1180
        }
      })

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-07",
        state: "worked",
        invoices: [invoice],
        issues: Gstr1.validation_issues([invoice]),
        derived_gstr1: Gstr1.derive([invoice], Gstr1.production_header(client.gstin, "2026-07"))
      })

    %{conn: log_in_user(conn, user), client: client, month: month, user: user, org: org}
  end

  test "rejects every export for an existing empty working", %{
    conn: conn,
    client: client,
    month: month
  } do
    {:ok, _} =
      Months.upsert(%{
        org_id: month.org_id,
        client_id: client.id,
        period: month.period,
        state: "worked",
        invoices: [],
        issues: [],
        derived_gstr1: Gstr1.derive([], Gstr1.production_header(client.gstin, month.period))
      })

    for filename <- ["return.json", "winman-b2b.xlsm", "workings.xlsx"] do
      response_conn = get(conn, "/gstr1/#{client.id}/#{month.period}/#{filename}")
      assert response(response_conn, 422)
      assert get_resp_header(response_conn, "content-disposition") == []
    end
  end

  test "downloads the current B2B workings as a Winman workbook", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/winman-b2b.xlsm")

    assert response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "application/vnd.ms-excel.sheet.macroEnabled.12"
           ]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "gstr1_#{client.gstin}_2026-07_winman_b2b.xlsm"

    sheet = conn.resp_body |> entries() |> Map.fetch!("xl/worksheets/sheet2.xml")
    assert sheet =~ "INV-001"
    assert sheet =~ "Customer &amp; Co"
    assert sheet =~ "Karnataka"
    assert sheet =~ ~s(<c r="H6" s="97"><v>180.0</v></c>)
  end

  test "downloads the accountant-facing sales working as a consolidated XLSX", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/workings.xlsx")

    assert response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
           ]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "gst_sales_working_Breeze_Tech_#{client.gstin}_2026-07.xlsx"

    files = entries(conn.resp_body)
    workbook = Map.fetch!(files, "xl/workbook.xml")
    strings = Map.fetch!(files, "xl/sharedStrings.xml")

    for sheet <- ["Sales", "Tax Working", "HSN"] do
      assert workbook =~ ~s(name="#{sheet}")
    end

    assert strings =~ "INV-001"
    assert strings =~ "Customer &amp; Co"
    assert strings =~ "Calculated IGST"
  end

  test "working filenames safely preserve non-ASCII client names", %{conn: conn, client: client} do
    client |> Ecto.Changeset.change(name: "தமிழ் / Sales \"Company\"") |> Nila.Repo.update!()
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/workings.xlsx")
    assert response(conn, 200)
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "filename*=UTF-8''"
    [_, encoded] = String.split(disposition, "filename*=UTF-8''")
    filename = URI.decode(encoded)
    assert filename =~ "தமிழ"
    assert filename =~ "_Sales_Company_#{client.gstin}_2026-07.xlsx"
    refute filename =~ "/"
    refute filename =~ "\""
  end

  test "downloads current sales workings as Tally XML", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/tally.xml")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "sales_#{client.gstin}_2026-07_tally.xml"

    assert conn.resp_body =~ "<TALLYREQUEST>Import</TALLYREQUEST>"
    assert conn.resp_body =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"
    assert conn.resp_body =~ "<LEDGERNAME>Customer &amp; Co</LEDGERNAME>"
    assert conn.resp_body =~ "<LEDGERNAME>Output IGST</LEDGERNAME>"
    assert conn.resp_body =~ "<AMOUNT>180.00</AMOUNT>"
  end

  test "downloads the filed sales position as Tally XML", %{
    conn: conn,
    client: client,
    month: month,
    user: user
  } do
    Nila.GstFixtures.answer_sales_issues!(month, user.id)

    assert {:ok, filed} =
             Nila.Gst.Filing.Signoffs.mark_filed_gstr1(month, Nila.Accounts.Scope.for_user(user))

    assert filed.filed_at
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/tally.xml")
    assert response(conn, 200)
    assert conn.resp_body =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"
    assert conn.resp_body =~ "<LEDGERNAME>Customer &amp; Co</LEDGERNAME>"
  end

  test "the legacy month posting endpoint opens sales bills without creating jobs", %{
    conn: conn,
    client: client
  } do
    conn = post(conn, ~p"/gstr1/#{client.id}/2026-07/tally", %{"tally" => %{"company_id" => "7"}})
    assert redirected_to(conn) == ~p"/gst/#{client.id}/2026-07/sales"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Open the sales bills"
    assert Repo.aggregate(Job, :count) == 0
  end

  test "does not expose another organisation's workbook", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> get(~p"/gstr1/#{client.id}/2026-07/winman-b2b.xlsm")

    assert response(conn, 404) == "Not found"
  end

  test "does not expose another organisation's sales working", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> get(~p"/gstr1/#{client.id}/2026-07/workings.xlsx")

    assert response(conn, 404) == "Not found"
  end

  test "does not expose another organisation's Tally XML", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> get(~p"/gstr1/#{client.id}/2026-07/tally.xml")

    assert response(conn, 404) == "Not found"
  end

  test "does not send another organisation's sales to Tally", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> post(~p"/gstr1/#{client.id}/2026-07/tally")

    assert response(conn, 404) == "Not found"
  end

  test "does not let an operator from another org use the month posting endpoint", %{
    client: client
  } do
    %{user: operator} = user_with_org_fixture(%{role: "member"})

    conn =
      build_conn()
      |> log_in_user(operator)
      |> post(~p"/gstr1/#{client.id}/2026-07/tally")

    assert response(conn, 404) == "Not found"
    assert Repo.aggregate(Job, :count) == 0
  end

  defp entries(workbook) do
    {:ok, entries} = :zip.extract(workbook, [:memory])
    Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
  end
end
