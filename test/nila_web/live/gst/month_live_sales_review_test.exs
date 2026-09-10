defmodule NilaWeb.Gst.MonthLiveSalesReviewTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Clients

  @period "2025-10"

  test "special treatment corrections use choices and preserve the original evidence", context do
    alias Nila.Gst.Sales.{Gstr1, Months}
    alias Nila.Gst.Sales.Review.Resolutions

    pages =
      "test/fixtures/gstr1/tally/2026-06/extraction.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("pages")

    invoice =
      pages |> Enum.at(3) |> Normalizer.normalize() |> Map.put("tax_payment", "unknown")

    {:ok, month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: "2026-06",
        state: "worked",
        invoices: [invoice],
        issues: Gstr1.validation_issues([invoice]),
        derived_gstr1:
          Gstr1.derive([invoice], Gstr1.production_header(context.client.gstin, "2026-06"))
      })

    [source] = Resolutions.workings(month).active_invoices

    {:ok, view, _} =
      live(
        context.conn,
        "/gst/#{context.client.id}/2026-06/review/sales?item=#{source["id"]}&scope=needs_you"
      )

    for {field, value, label} <- [
          {"tax_payment", "without_payment", "Without payment (LUT/bond)"},
          {"reverse_charge", "false", "Not reverse charge"}
        ] do
      view |> element("button[phx-value-field='#{field}']", "Correct") |> render_click()
      assert has_element?(view, "#gstr1-correction-form select option[value='#{value}']", label)

      view
      |> form("#gstr1-correction-form", %{"correction" => %{"field" => field, "value" => value}})
      |> render_submit()
    end

    result = Resolutions.workings(month)
    assert hd(result.invoices)["reverse_charge"] == false
    assert hd(result.invoices)["tax_payment"] == "without_payment"
    assert Gstr1.filing_table(hd(result.invoices)) == "b2b"

    refute Enum.any?(
             result.issues,
             &(&1["code"] in ~w(missing_tax_payment special_supply_conflict))
           )

    assert hd(Nila.Repo.reload!(month).invoices)["reverse_charge"] == true
  end

  test "an unregistered note's original sale can be reviewed without entering internal codes",
       context do
    alias Nila.Gst.Sales.{Gstr1, Months}
    alias Nila.Gst.Sales.Review.Resolutions
    {:ok, month} = Months.get_by_period(context.org.id, context.client.id, @period)

    note =
      hd(month.invoices)
      |> Map.put("document_type", "credit_note")
      |> Map.put("document", %{"credit_note" => true})
      |> Map.put("recipient_registration", "unregistered")
      |> Map.put("buyer_gstin", nil)
      |> Map.put("place_of_supply", "29")
      |> Map.put("original_sale_category", nil)

    {:ok, month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: @period,
        invoices: [note],
        issues: Gstr1.validation_issues([note]),
        derived_gstr1:
          Gstr1.derive([note], Gstr1.production_header(context.client.gstin, @period))
      })

    [source] = Resolutions.workings(month).active_invoices

    {:ok, view, _html} =
      live(
        context.conn,
        "/gst/#{context.client.id}/#{@period}/review/sales?item=#{source["id"]}&scope=needs_you"
      )

    view
    |> element("button[phx-value-field='original_sale_category']", "Correct")
    |> render_click()

    assert has_element?(
             view,
             "#gstr1-correction-form select option[value='b2cs']",
             "B2C Other / Small"
           )

    assert has_element?(view, "#gstr1-correction-form select option[value='b2cl']", "B2C Large")

    view
    |> form("#gstr1-correction-form", %{
      "correction" => %{"field" => "original_sale_category", "value" => "b2cl"}
    })
    |> render_submit()

    result = Resolutions.workings(month)
    assert hd(result.invoices)["original_sale_category"] == "b2cl"
    assert length(result.derived["cdnur"]) == 1
    refute Enum.any?(result.issues, &(&1["code"] == "missing_original_sale_category"))
  end

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

  test "the invoice row owns issue review without a detached next-issue action", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Review.Resolutions.workings(month).active_invoices

    refute has_element?(view, "#month-door-sales-issues")
    refute has_element?(view, "#month-door-review-issue")
    refute has_element?(view, "#gstr1-evidence-modal")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=needs_you"
    )

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-checks button", "Accept the extracted lines")

    assert has_element?(
             view,
             "#gstr1-rate-validation-scope",
             "HSN/SAC codes and tax arithmetic are checked. Printed rates are preserved."
           )
  end

  test "opening, adjacent navigation, and Done patch without unmounting MonthLive", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "printed_grand_total", 1)

        invoice ->
          invoice
      end)

    {:ok, updated} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    [first, second | _] = Nila.Gst.Sales.Review.Resolutions.workings(updated).active_invoices
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")
    month_pid = view.pid

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{first["id"]}&scope=needs_you"
    )

    view |> element("#gstr1-review-next") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{second["id"]}&scope=needs_you"
    )

    view |> element("#gstr1-review-previous") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{first["id"]}&scope=needs_you"
    )

    view |> element("#sales-review button[phx-click='done']") |> render_click()
    assert_patch(view, "/gst/#{client.id}/#{@period}?track=sales")
    assert view.pid == month_pid
    refute has_element?(view, "#gstr1-evidence-modal")
  end

  test "the invoice review URL survives refresh and Done returns to the register", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Review.Resolutions.workings(month).active_invoices

    review_path =
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=needs_you"

    {:ok, view, _html} = live(conn, review_path)

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-review-header", "1 to answer")
    assert has_element?(view, "#gstr1-review-header", "Filing blocked")
    assert has_element?(view, "#gstr1-review-previous[disabled]", "Previous")
    assert has_element?(view, "#gstr1-review-next[disabled]", "Next")
    assert has_element?(view, "[data-review-target='gstr1-line-total']")
    assert has_element?(view, "[data-review-target='gstr1-line-total'] span", "1")

    view |> element("#sales-review button[phx-click='done']") |> render_click()

    assert_patch(view, "/gst/#{client.id}/#{@period}?track=sales")
    refute has_element?(view, "#gstr1-evidence-modal")

    assert view |> element("#gstr1-inv-20\\/2025-26") |> render() =~
             "nila-sales-register-row-reviewed"
  end

  test "previous and next flagged invoice stay inside the route-backed review queue", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    invoices =
      Enum.map(month.invoices, fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "printed_grand_total", 1)

        invoice ->
          invoice
      end)

    {:ok, updated_month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, @period))
      })

    next_id =
      updated_month.invoices
      |> Enum.find(&(&1["invoice_number"] == "21/2025-26"))
      |> Map.fetch!("id")

    first_id =
      updated_month.invoices
      |> Enum.find(&(&1["invoice_number"] == "20/2025-26"))
      |> Map.fetch!("id")

    path = "/gst/#{client.id}/#{@period}/review/sales?item=#{first_id}&scope=needs_you"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#gstr1-review-next:not([disabled])", "Next")
    view |> element("#gstr1-review-next") |> render_click()

    assert_patch(
      view,
      "/gst/#{client.id}/#{@period}/review/sales?item=#{next_id}&scope=needs_you"
    )

    assert has_element?(view, "#gstr1-evidence-modal-title", "21/2025-26")
    assert has_element?(view, "#gstr1-review-previous:not([disabled])")
  end

  test "same-kind issue chips are distinct and point to their own evidence", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-12"

    line = %{
      "description" => "Service",
      "hsn_sac" => "998719",
      "printed_taxable_value" => 1.06,
      "cgst_rate" => 9,
      "cgst_amount" => 0.10,
      "sgst_rate" => 9,
      "sgst_amount" => 0.10
    }

    invoice =
      Normalizer.normalize(%{
        "data" => %{
          "invoice_number" => "44/2026-27",
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Philips India", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => List.duplicate(line, 4)
        }
      })

    invoices = [invoice]
    issues = Gstr1.validation_issues(invoices)

    assert Enum.count(issues, &(&1["code"] == "rounding_variance")) == 2

    {:ok, review_month} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: issues,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    [review_invoice] = Nila.Gst.Sales.Review.Resolutions.workings(review_month).active_invoices

    path =
      "/gst/#{client.id}/#{period}/review/sales?item=#{review_invoice["id"]}&scope=all"

    {:ok, view, _html} = live(conn, path)

    # Both are `info` — Nila settled them itself — so the modal counts what the
    # register counts, and neither offers an action that would change nothing.
    assert has_element?(view, "#gstr1-review-header", "Nothing left to answer")
    assert has_element?(view, "#gstr1-review-header", "CGST rounding difference")
    assert has_element?(view, "#gstr1-review-header", "SGST rounding difference")
    assert has_element?(view, "#gstr1-evidence-modal", "explained by per-line rounding, accepted")
    refute has_element?(view, "#gstr1-evidence-modal button", "Keep extracted value")

    targets =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-review-header button[data-review-target]")
      |> LazyHTML.attribute("data-review-target")

    assert length(targets) == 2
    assert length(Enum.uniq(targets)) == 2
    Enum.each(targets, &assert(has_element?(view, "##{&1}")))
  end

  test "clicking an invoice shows its issues in the evidence modal", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    assert has_element?(view, "#gstr1-evidence-modal")
    assert has_element?(view, "#gstr1-evidence-modal [id^='gstr1-issue-'] p")
    assert render(view) =~ "Bill total doesn&#39;t tally"
    assert has_element?(view, "#gstr1-checks dt", "Printed bill total")
    assert has_element?(view, "#gstr1-checks dt", "Sum of extracted lines")
    # The difference is why the card is open, so it is a term, not subtraction
    # left to the reader.
    assert has_element?(view, "#gstr1-checks dt", "Difference")
  end

  test "the invoice modal shows the extracted read beside validation-judged checks", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()

    assert has_element?(view, "#gstr1-line-items")
    modal = view |> element("#gstr1-evidence-modal") |> render()

    # The full read: description, HSN, rate, taxable, tax split.
    assert modal =~ "AC service"
    assert modal =~ "8415"
    assert modal =~ "18%"
    # Total first, split persistent beneath it — not a hover tooltip.
    assert modal =~ "2,160.00"
    assert modal =~ "CGST 1,080.00 · SGST 1,080.00"

    # Checks render as the arithmetic the bill printed, judged by validation.
    assert modal =~ "12,000.00 × 18% = 2,160.00"
    assert modal =~ "CGST 1,080.00 = SGST 1,080.00"
    assert modal =~ "grand total: lines 14,160.00 = printed 14,160.00"
  end

  test "a failed check is its issue card rendered in place, not duplicated below", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    # The failing grand-total check renders the confirmable issue inside the
    # checks block — one judge, one rendering.
    assert has_element?(view, "#gstr1-checks button", "Accept the extracted lines")

    modal = view |> element("#gstr1-evidence-modal") |> render()
    # One compact header shortcut and one issue card; the issue is not repeated
    # in a detached section below the checks.
    assert length(String.split(modal, "Bill total doesn&#39;t tally")) == 3
  end

  test "opening an invoice marks its row read for the session", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    assert view |> element("#gstr1-inv-21\\/2025-26") |> render() =~ "font-medium"

    view |> element("#gstr1-inv-21\\/2025-26") |> render_click()
    view |> element("#sales-review button[phx-click='done']") |> render_click()

    row = view |> element("#gstr1-inv-21\\/2025-26") |> render()
    refute row =~ "font-medium"
    assert row =~ "text-ink-muted"
  end

  test "confirming an issue resolves it; undo reopens it", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)
    [invoice | _] = Nila.Gst.Sales.Review.Resolutions.workings(month).active_invoices
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    assert has_element?(view, "#gstr1-what-changed", "Confirmation · invoice 20/2025-26")
    assert has_element?(view, "#gstr1-what-changed", "totals did not change")

    resolved_path =
      "/gst/#{client.id}/#{@period}/review/sales?item=#{invoice["id"]}&scope=all"

    {:ok, resolved, _html} = live(conn, resolved_path)
    assert render(resolved) =~ "Resolved by #{user.name}"
    assert render(resolved) =~ "Accepted extracted line total"

    resolved
    |> element("#gstr1-checks button[phx-click='undo']", "Undo")
    |> render_click()

    {:ok, reopened, _html} = live(conn, resolved_path)
    refute render(reopened) =~ "Resolved by #{user.name}"
  end

  test "Nila states a position, its basis, and what it files — and freezes it", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    modal = view |> element("#gstr1-evidence-modal") |> render()

    # Three parts, never two: what Nila would do, what it observed to think so,
    # and what that puts in the return.
    assert modal =~ "Nila&#39;s read"
    assert modal =~ "Accept the extracted lines"
    assert modal =~ "only the printed bill total disagrees"
    assert modal =~ "Files "

    # And the position is the button, not a sentence above one. Naming the
    # action in prose and then offering buttons of equal weight makes the
    # reviewer match the two by eye — a position you have to locate is a
    # paragraph. The action string appears once, and it is what you click.
    assert has_element?(
             view,
             "button[phx-click='resolve-invoice-issue']",
             "Accept the extracted lines"
           )

    refute view
           |> element("#gstr1-evidence-modal [id$='-proposal']")
           |> render() =~ "Accept the extracted lines"

    view
    |> element("button[phx-click='resolve-invoice-issue']", "Accept the extracted lines")
    |> render_click()

    # What the reviewer was shown is now part of the record, so a later rule
    # change cannot rewrite what this screen claimed Nila advised.
    {:ok, month} = Nila.Gst.Sales.Months.get_by_period(org.id, client.id, @period)

    frozen =
      month.id
      |> Nila.Gst.Sales.Review.Resolutions.list()
      |> Enum.find_value(& &1.payload["proposal"])

    assert frozen["action"] == "Accept the extracted lines"
    assert frozen["rule_version"]
    assert frozen["basis"] =~ "only the printed bill total disagrees"
    assert frozen["effect"]["schema_version"] == 1
    assert frozen["effect"]["kind"] == "filing_result"
    assert frozen["effect"]["amounts"]["tax_paise"] > 0
  end

  test "the three tax figures are named apart, and the action states what it files", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    # The register reads the extraction and says so; the workings read the
    # recomputation and say so. "Tax" alone named all three. Column labels live
    # in the <thead>, which sits outside the <tbody> the id is on — so these
    # assert against the enclosing sections.
    # The column names what the figure is before where it came from: it sits
    # immediately after Taxable, so a bare "Sum of extracted lines" read as a
    # second take on the taxable value rather than as the tax.
    assert has_element?(view, "#gstr1-register th", "POS")
    assert has_element?(view, "#gstr1-inv-20\\/2025-26", "33")
    assert has_element?(view, "#gstr1-register th", "Extracted GST")
    assert has_element?(view, "#gstr1-register-basis.text-ui", "per-rate recomputation")
    refute has_element?(view, "#gstr1-register-basis.text-context")
    assert has_element?(view, "#gstr1-workings-basis.text-ui", "what this return files")
    refute has_element?(view, "#gstr1-workings-basis.text-context")
    assert has_element?(view, "#gstr1-workings-b2b th", "Output tax")
    assert has_element?(view, "#gstr1-workings-rates th", "Output tax")
    assert has_element?(view, "#gstr1-workings-hsn th", "Output tax")
    refute has_element?(view, "#gstr1-workings-b2b th", "GSTR-1 tax")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    # The modal's mismatch card compares two readings of the document, and
    # neither of them is filed — so the card says what accepting actually puts
    # in the return.
    modal = view |> element("#gstr1-evidence-modal") |> render()
    assert modal =~ "Files "
    assert modal =~ "tax on "
    assert modal =~ "taxable"
  end

  test "correcting a flagged field re-derives and clears the issue", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{@period}?track=sales")

    view |> element("#gstr1-inv-20\\/2025-26") |> render_click()

    view
    |> element("button[phx-value-field='printed_grand_total']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{
      "correction" => %{"field" => "printed_grand_total", "value" => "76171.36"}
    })

    refute render(view) =~ "Bill total doesn&#39;t tally"
  end

  test "a correction ripples the changed workings nodes and leaves the rest quiet", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-12"

    invoices = [
      # The tax amounts disagree with the rate, so the line's fields are
      # flagged and taxable_value is correctable through the modal.
      Normalizer.normalize(%{
        "data" => %{
          "invoice_number" => "40/2025-26",
          "invoice_date" => "04.12.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{
              "printed_taxable_value" => 1000,
              "hsn_sac" => "8415",
              "cgst_rate" => 9,
              "cgst_amount" => 100,
              "sgst_rate" => 9,
              "sgst_amount" => 90
            }
          ]
        }
      }),
      Normalizer.normalize(%{
        "data" => %{
          "invoice_number" => "41/2025-26",
          "invoice_date" => "06.12.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "SIEMENS HEALTHCARE", "gstin" => "33AAVCS8021P1ZM"},
          "line_items" => [
            %{
              "printed_taxable_value" => 2000,
              "hsn_sac" => "2903",
              "cgst_rate" => 9,
              "cgst_amount" => 180,
              "sgst_rate" => 9,
              "sgst_amount" => 180
            }
          ]
        }
      })
    ]

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period)),
        issues: Gstr1.validation_issues(invoices),
        summary: %{"invoice_count" => 2, "issue_count" => 1}
      })

    {:ok, view, _html} = live(conn, "/gst/#{client.id}/#{period}?track=sales")

    refute render(view) =~ "workings-ripple"

    view |> element("#gstr1-inv-40\\/2025-26") |> render_click()

    view
    |> element("button[phx-value-field='line_items[0].printed_taxable_value']", "Correct")
    |> render_click()

    view
    |> element("form[phx-submit='save_correct']")
    |> render_submit(%{
      "correction" => %{
        "field" => "line_items[0].printed_taxable_value",
        "value" => "1500"
      }
    })

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#gstr1-what-changed",
             "Correction · invoice 40/2025-26 · Line items[0] printed taxable value"
           )

    assert has_element?(view, "#gstr1-what-changed", "Proposed GSTR-1 changed from")

    # The nodes the re-derivation changed glow: party, rate bucket, HSN row,
    # and the month total in the account.
    assert view |> element("#gstr1-workings-party-33AABCP9487A1ZG") |> render() =~
             "workings-ripple"

    assert view |> element("#gstr1-workings-rate-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-workings-hsn-8415-18") |> render() =~ "workings-ripple"
    assert view |> element("#gstr1-verdict") |> render() =~ "workings-ripple"

    refute has_element?(view, "#gstr1-draft-reconciliation")
    assert has_element?(view, "#gstr1-filing-b2b", "₹3,500.00")
    assert has_element?(view, "#gstr1-filing-status", "Provisional")

    # The other party's numbers did not move, so its node stays quiet.
    refute view |> element("#gstr1-workings-party-33AAVCS8021P1ZM") |> render() =~
             "workings-ripple"

    refute view |> element("#gstr1-workings-hsn-2903-18") |> render() =~ "workings-ripple"

    # A resolution that changes no derived number clears the glow entirely.
    view
    |> element(
      "button[phx-click='resolve-invoice-issue'][phx-value-target$=':cgst_sgst_unequal']"
    )
    |> render_click()

    refute render(view) =~ "workings-ripple"
  end

  # Two lines of one bill fail the same check, so they are one issue against one
  # resolution target. `check_issues` is keyed per check and both checks resolve
  # to that issue, so a card per check put the same question on the page twice
  # under the same DOM id — `issue_dom_id/1` names the issue, and the issue is
  # one. Duplicate ids are invalid HTML and are what LiveView patches by.
  test "a merged line issue is one card, and every failing line still gets its ✗", %{
    conn: conn,
    org: org,
    client: client
  } do
    alias Nila.Gst.Sales.Gstr1
    alias Nila.Gst.Sales.Months, as: SalesMonths

    period = "2025-11"

    # Lines 1 and 3 don't multiply out; line 2 does.
    invoices = [
      Normalizer.normalize(%{
        "data" => %{
          "invoice_number" => "41/2025-26",
          "invoice_date" => "04.11.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AAVCS8021P1ZB"},
          "line_items" => [
            arithmetic_line("Silver rod", 1000, 50),
            arithmetic_line("Silver wire", 500, 45),
            arithmetic_line("Silver sheet", 200, 10)
          ]
        }
      })
    ]

    failed = invoices |> hd() |> InvoiceValidation.checks() |> Enum.reject(& &1["passed"])
    assert length(failed) == 2

    {:ok, _} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        invoices: invoices,
        issues: Gstr1.validation_issues(invoices),
        derived_gstr1: Gstr1.derive(invoices, Gstr1.production_header(client.gstin, period))
      })

    assert {:error, {:live_redirect, %{to: review_path}}} =
             live(conn, ~p"/gst/#{client.id}/#{period}?invoice=41%2F2025-26")

    {:ok, view, _html} = live(conn, review_path)

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gstr1-checks [id^='gstr1-issue-']")
      |> LazyHTML.attribute("id")

    assert ids == ["gstr1-issue-line_arithmetic-line-1"]
    assert ids == Enum.uniq(ids)

    # The card names both lines, and line 3's own ✗ still states its arithmetic
    # — the question is asked once, nothing that failed goes unsaid.
    checks = view |> element("#gstr1-checks") |> render()
    assert checks =~ "line 1 tax 100"
    assert checks =~ "line 3 tax 20"
    assert checks =~ "L3: 200.00 × 18% = 20.00"
  end

  # The panel's HSN gate expands the workings rows for the code an issue carries
  # and unlocks the answer once they are all open. A merged issue therefore has
  # to carry every code it covers: holding only the first, reviewing 999999's
  # rows would clear an invoice whose 888888 rows were never rendered. Before
  # the collapse that took two separate reviews, and it still has to.
  test "a two-bad-code invoice cannot be covered by reviewing one of them" do
    alias Nila.Gst.Hsn.Validation, as: HsnValidation
    alias NilaWeb.Components.Gst.Month.Workings

    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "50/2025-26",
        "line_items" => [bad_hsn_line("Bogus", "999999"), bad_hsn_line("Also bogus", "888888")]
      }
    ]

    assert [issue] = HsnValidation.sales_issues(invoices)
    assert issue["hsn_codes"] == ["999999", "888888"]

    reviewed = MapSet.new(Workings.hsn_node_ids(invoices, "999999"))

    required =
      Enum.flat_map(issue["hsn_codes"], &Workings.hsn_node_ids(invoices, &1))

    assert reviewed != MapSet.new()
    assert required != []
    refute Enum.all?(required, &MapSet.member?(reviewed, &1))
  end

  defp arithmetic_line(description, taxable, half_tax) do
    %{
      "description" => description,
      "hsn_sac" => "7106",
      "printed_taxable_value" => taxable,
      "cgst_rate" => 9,
      "cgst_amount" => half_tax,
      "sgst_rate" => 9,
      "sgst_amount" => half_tax
    }
  end

  defp bad_hsn_line(description, code) do
    %{
      "description" => description,
      "hsn_sac" => code,
      "hsn_validation" => %{"status" => "invalid", "code" => code},
      "taxable_value" => 1000,
      "cgst_rate" => 9,
      "cgst_amount" => 90,
      "sgst_rate" => 9,
      "sgst_amount" => 90
    }
  end
end
