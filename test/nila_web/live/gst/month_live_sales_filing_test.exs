defmodule NilaWeb.Gst.MonthLiveSalesFilingTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Clients

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes", user.id)

    %{conn: log_in_user(conn, user), org: org, client: client, user: user}
  end

  test "the sales workspace offers reviewed outputs without a separate approval step", %{
    conn: conn,
    client: client,
    user: user
  } do
    {:ok, _review_view, _html} = live(conn, "/gst/#{client.id}/#{@period}/sales")
    ready!(client, user)

    {:ok, workspace, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(
             workspace,
             "#sales-period-status",
             "Your GST working is available to download."
           )

    assert has_element?(workspace, "#sales-period-handoff-winman", "Winman GSTR-1")
    assert has_element?(workspace, "#sales-period-export")
    assert has_element?(workspace, "#sales-period-primary-action", "Download GST working")
    assert has_element?(workspace, "#sales-period-primary-action", "Add invoices")
    refute has_element?(workspace, "#sales-period-primary-action", "Bring in invoices")
    refute has_element?(workspace, "#sales-period-primary-action", "Approve GSTR-1")

    assert has_element?(
             workspace,
             "#sales-period-primary-download[href='/gstr1/#{client.id}/#{@period}/workings.xlsx']"
           )

    assert has_element?(
             workspace,
             "#sales-period-handoff-download-json[href='/gstr1/#{client.id}/#{@period}/return.json']",
             "Download"
           )
  end

  test "ready Winman manifest matches B2B export rows and discloses omitted sections", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    alias Nila.Gst.Filing.WinmanGstr1
    alias Nila.Gst.Sales.{Gstr1, Months}
    alias Nila.Gst.Sales.Review.Resolutions

    period = "2026-07"

    registered =
      Normalizer.normalize(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "33",
          "invoice_number" => "B2B-1",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Registered buyer", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "description" => "Fixture goods",
              "hsn_sac" => "8471",
              "printed_taxable_value" => 1_000,
              "cgst_rate" => 2.5,
              "cgst_amount" => 25,
              "sgst_rate" => 2.5,
              "sgst_amount" => 25
            },
            %{
              "description" => "Fixture service",
              "hsn_sac" => "9987",
              "printed_taxable_value" => 500,
              "cgst_rate" => 9,
              "cgst_amount" => 45,
              "sgst_rate" => 9,
              "sgst_amount" => 45
            }
          ],
          "printed_total_taxable" => 1_500,
          "printed_total_tax" => 140,
          "printed_grand_total" => 1_640
        }
      })
      |> Map.put("id", "b2b-original")

    duplicate = Map.put(registered, "id", "b2b-duplicate")

    b2cs =
      Normalizer.normalize(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "unregistered",
          "place_of_supply" => "33",
          "invoice_number" => "B2CS-1",
          "invoice_date" => "16.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Cash buyer", "gstin" => nil},
          "line_items" => [
            %{
              "description" => "Fixture goods",
              "hsn_sac" => "8471",
              "printed_taxable_value" => 200,
              "cgst_rate" => 9,
              "cgst_amount" => 18,
              "sgst_rate" => 9,
              "sgst_amount" => 18
            }
          ],
          "printed_total_taxable" => 200,
          "printed_total_tax" => 36,
          "printed_grand_total" => 236
        }
      })
      |> Map.put("id", "b2cs-one")

    invoices = [registered, duplicate, b2cs]

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    assert {:ok, [_excluded]} =
             Resolutions.exclude_duplicate_copies(month, registered["id"], user.id)

    answer_sales_issues!(month, user.id)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}/sales")
    assert has_element?(view, "#sales-period-handoff-winman")

    {:ok, reviewed_month} = Months.get_by_period(org.id, client.id, period)
    projection = Resolutions.effective_workings(reviewed_month)
    assert {:ok, manifest} = WinmanGstr1.export_manifest(projection)

    export_conn =
      get(conn, ~p"/gstr1/#{client.id}/#{period}/winman-b2b.xlsm")

    workbook = response(export_conn, 200)
    {:ok, entries} = :zip.extract(workbook, [:memory])

    b2b_sheet =
      Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
      |> Map.fetch!("xl/worksheets/sheet2.xml")

    exported_rows =
      ~r/<row r="(\d+)"/
      |> Regex.scan(b2b_sheet, capture: :all_but_first)
      |> Enum.count(fn [row] -> String.to_integer(row) >= 6 end)

    assert manifest.included_documents == exported_rows
    assert manifest.included_documents == 2
    assert manifest.duplicates_excluded == 1
    assert manifest.omitted_documents == 1
    assert_in_delta manifest.taxable, 1_500, 0.001
    assert_in_delta manifest.output_tax, 140, 0.001
  end

  test "ready sales files need no approval and remain editable", %{
    conn: conn,
    client: client,
    user: user
  } do
    ready!(client, user)
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/sales")
    assert has_element?(view, "#sales-period-primary-download")
    assert has_element?(view, "#sales-period-primary-download", "Download GST working")
    assert has_element?(view, "#sales-period-handoff-download-json")
    refute has_element?(view, "#month-door-sign-r1")
    refute has_element?(view, "#gstr1-reopen-signoff")
    refute has_element?(view, "#month-exit-gstr1", "Approved by")
  end

  test "a member downloads ready workings without waiting for approval", %{
    org: org,
    client: client
  } do
    member = Nila.AccountsFixtures.user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(build_conn(), member)

    ready!(client, member)
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}/sales")

    refute has_element?(view, "#month-door-sign-r1")
    assert has_element?(view, "#sales-period-primary-download")
    assert has_element?(view, "#sales-period-status", "Your GST working is available")
    assert has_element?(view, "#sales-period-handoff-download-json", "Download")
  end

  test "downloads the portal-shaped GSTR-1 JSON", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response_content_type(conn, :json)
    body = json_response(conn, 200)
    assert body["gstin"] == "33AEWPH4158J1Z3"
    assert body["fp"] == "102025"
    assert is_list(body["b2b"])
  end

  test "another org cannot open the month or fetch the JSON", %{client: client} do
    %{user: other_user} = user_with_org_fixture()
    conn = log_in_user(build_conn(), other_user)

    assert {:error, {:live_redirect, %{to: "/today"}}} =
             live(conn, "/gst/#{client.id}/#{@period}/sales")

    conn =
      get(build_conn() |> log_in_user(other_user), ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response(conn, 404)
  end

  defp ready!(client, user) do
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(client.org_id, client.id, @period)
    answer_sales_issues!(month, user.id)
  end
end
