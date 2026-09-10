defmodule NilaWeb.Gst.MonthLiveSalesFilingTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures
  import NilaWeb.Gst.MonthLiveSalesHelpers, only: [confirm_all_open_issues: 1]

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
    client: client
  } do
    {:ok, review_view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    confirm_all_open_issues(review_view)

    {:ok, workspace, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales")

    assert has_element?(
             workspace,
             "#sales-period-status",
             "Your GST working is available to download."
           )

    assert has_element?(workspace, "#sales-period-handoff-winman", "Winman GSTR-1")
    assert has_element?(workspace, "#sales-period-export")
    assert has_element?(workspace, "#sales-period-primary-action", "Download GST working")
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

  test "an unfiled legacy approval does not freeze current workings", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    confirm_all_open_issues(view)
    legacy_signoff!(org, client, user, false)
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    assert has_element?(view, "#gstr1-overview[data-state='ready']")
    assert has_element?(view, "#gstr1-primary-handoff", "Download working Excel")
    refute has_element?(view, "#gstr1-reopen-signoff")
    refute has_element?(view, "#month-door-sign-r1")
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")
    assert has_element?(view, "#gstr1-primary-handoff")

    assert has_element?(view, "#gstr1-handoff-manifest", "2 B2B workbook rows")
    assert has_element?(view, "#gstr1-handoff-manifest", "From 1 B2B invoice")

    assert has_element?(
             view,
             "#gstr1-handoff-manifest",
             "1 supported document omitted from this B2B workbook version · B2CS 1"
           )

    assert has_element?(view, "#gstr1-handoff-manifest", "1 duplicate copy")
    assert has_element?(view, "#gstr1-handoff-manifest", "₹1,500.00 taxable · ₹140.00 tax")

    {:ok, signed_month} = Months.get_by_period(org.id, client.id, period)
    projection = Resolutions.effective_workings(signed_month)
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

  test "a filed legacy snapshot keeps its original issue history", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    alias Nila.Gst.Filing.Signoffs
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    confirm_all_open_issues(view)
    legacy_signoff!(org, client, user, true)

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {:ok, signoff} = Signoffs.latest_gstr1_signoff(month.id)

    # Rewind the frozen issues to the pre-classification shape: `"warning"` for
    # compliance checks and no level at all for arithmetic ones. Signed history
    # is never migrated, so the read path has to carry it.
    legacy =
      Enum.map(signoff.snapshot["issues"], fn issue ->
        case issue["level"] do
          "required" -> Map.put(issue, "level", "warning")
          "advisory" -> Map.put(issue, "level", "warning")
          _settled_or_blocking -> Map.delete(issue, "level")
        end
      end)

    signoff
    |> Ecto.Changeset.change(snapshot: Map.put(signoff.snapshot, "issues", legacy))
    |> Nila.Repo.update!()

    {:ok, legacy_view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    # Everything was resolved before signing, so no legacy level may resurrect a
    # check, and the approved draft still renders.
    assert has_element?(legacy_view, "#gstr1-overview[data-state='filed']")
    refute has_element?(legacy_view, "#gstr1-checks-before-filing")
    assert legacy_view |> element("#gstr1-workings-b2b") |> render() =~ "PONMANI AND CO"
  end

  test "historical filed-return differences remain attributed and lock only after filing",
       %{conn: conn, org: org, client: client, user: user} do
    alias Nila.Gst.Sales.Months, as: SalesMonths
    alias Nila.Gst.Sales.Review.Resolutions, as: SalesResolutions

    # No filed return, no comparison — live months are untouched.
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    refute has_element?(view, "#gstr1-filed-comparison")

    # The filed return is the derived one with invoice 21's taxable moved:
    # exactly one field disagrees, and ours is right.
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    filed =
      update_in(month.derived_gstr1, ["b2b"], fn parties ->
        Enum.map(parties, fn party ->
          update_in(party, ["inv"], fn invs ->
            Enum.map(invs, fn
              %{"inum" => "21/2025-26"} = inv ->
                put_in(inv, ["itms", Access.at(0), "itm_det", "txval"], 13_000.0)

              inv ->
                inv
            end)
          end)
        end)
      end)

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        filed_gstr1: filed
      })

    legacy_signoff!(org, client, user, false)

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    # Differences live in one historical block; agreements stay silent.
    assert view |> element("#gstr1-filed-comparison") |> render() =~ "1 differ"
    assert length(String.split(render(view), ~s(phx-click="accept_difference"))) == 2

    target = "invoice_item|33AABCP9487A1ZG|21/2025-26|18|txval"

    row =
      view
      |> element("#gstr1-filed-comparison button[phx-value-target='#{target}']")
      |> render()

    assert row =~ "Ours is right"
    refute has_element?(view, "#gstr1-workings-b2b button[phx-value-target='#{target}']")

    body = render(view)
    assert body =~ "ours 12,000.00"
    assert body =~ "filed 13,000.00"

    # Legacy approval does not hide or block the attributed difference action.
    view |> element("button[phx-click='accept_difference']") |> render_click()

    assert render(view) =~ "Accepted — ours is right"

    accepted = Enum.filter(SalesResolutions.list(month.id), &(&1.verb == "accept_difference"))
    assert [%{target: ^target, decided_by_id: decided_by}] = accepted
    assert decided_by == user.id

    # Undo returns the difference to open.
    view |> element("button[phx-click='undo'][phx-value-target='#{target}']") |> render_click()
    assert has_element?(view, "button[phx-click='accept_difference']")

    view |> element("button[phx-click='accept_difference']") |> render_click()

    # An actually filed month keeps the comparison and prevents changes.
    confirm_all_open_issues(view)

    month
    |> Ecto.Changeset.change(filed_at: DateTime.utc_now(), state: "filed")
    |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(view, "#gstr1-diff-summary")
    assert render(view) =~ "Accepted — ours is right"
    refute has_element?(view, "button[phx-click='accept_difference']")
    refute has_element?(view, "button[phx-click='undo'][phx-value-target='#{target}']")
  end

  test "document-series differences survive without a documents-issued table", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    filed =
      put_in(
        month.derived_gstr1,
        ["doc_issue", "doc_det", Access.at(0), "docs", Access.at(0), "cancel"],
        1
      )

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        filed_gstr1: filed
      })

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert has_element?(
             view,
             "#gstr1-filed-comparison",
             "Invoice series · Cancelled: ours 0 · filed 1"
           )

    refute has_element?(view, "#gstr1-workings-docs")
  end

  test "ready sales files need no approval and remain editable", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    confirm_all_open_issues(view)
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    assert has_element?(view, "#gstr1-overview[data-state='ready']")
    assert has_element?(view, "#gstr1-primary-handoff", "Download working Excel")
    assert has_element?(view, "#gstr1-guide-download-json[download]")
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

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    confirm_all_open_issues(view)
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    refute has_element?(view, "#month-door-sign-r1")
    assert has_element?(view, "#gstr1-overview[data-state='ready']")
    assert has_element?(view, "#gstr1-filing-status", "Working files ready")
    assert has_element?(view, "#month-exit-gstr1", "Download the working files for review")
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
             live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    conn =
      get(build_conn() |> log_in_user(other_user), ~p"/gstr1/#{client.id}/#{@period}/return.json")

    assert response(conn, 404)
  end

  defp legacy_signoff!(org, client, user, filed?) do
    alias Nila.Gst.Sales.Months
    alias Nila.Gst.Sales.Review.Resolutions
    {:ok, month} = Months.get_by_period(org.id, client.id, @period)
    workings = Resolutions.workings(month)

    signoff =
      %Nila.Gst.Filing.Signoff{org_id: org.id, sales_month_id: month.id, signed_by_id: user.id}
      |> Nila.Gst.Filing.Signoff.changeset(%{
        artifact: "gstr1",
        snapshot: %{
          "derived" => workings.derived,
          "invoices" => workings.invoices,
          "printed_invoices" => workings.printed_active_invoices,
          "issues" => workings.issues
        }
      })
      |> Nila.Repo.insert!()

    if filed?,
      do:
        month
        |> Ecto.Changeset.change(filed_at: DateTime.utc_now(), state: "filed")
        |> Nila.Repo.update!()

    signoff
  end
end
