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
