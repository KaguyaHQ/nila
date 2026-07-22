defmodule Nila.Gst.Sales.WorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  @header Gstr1.production_header("33AEWPH4158J1Z3", "2026-05")

  # Stub-shaped raw pages run through the real normalizer, so these tests
  # exercise the same invoice shape production stores in sales_months.
  defp invoices do
    [
      # Poison total: printed grand total disagrees with line sum.
      raw(1, "20/2026-27", [line("Refrigeration unit", 55_552.0)], 2_75_000.0),
      raw(2, "21/2026-27", [line("AC service", 12_000.0)], 14_160.0),
      # Sequence gap: 22 is missing, 23 follows.
      raw(3, "23/2026-27", [line("134A Gas", 10_200.0)], 12_036.0)
    ]
    |> Enum.map(&Gstr1.normalize_invoice/1)
  end

  defp raw(page, inum, line_items, grand_total) do
    taxable = line_items |> Enum.map(& &1["taxable_value"]) |> Enum.sum()
    tax = line_items |> Enum.map(&(&1["cgst_amount"] + &1["sgst_amount"])) |> Enum.sum()

    %{
      "page" => page,
      "data" => %{
        "invoice_number" => inum,
        "invoice_date" => "04.05.2026",
        "seller" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => line_items,
        "printed_total_taxable" => taxable,
        "printed_total_tax" => tax,
        "printed_grand_total" => grand_total
      }
    }
  end

  defp line(description, taxable) do
    side = Float.round(taxable * 9.0 / 100, 2)

    %{
      "description" => description,
      "hsn_sac" => "8415",
      "quantity" => 1.0,
      "taxable_value" => taxable,
      "cgst_rate" => 9.0,
      "cgst_amount" => side,
      "sgst_rate" => 9.0,
      "sgst_amount" => side
    }
  end

  defp open_codes(result) do
    result.issues |> Enum.filter(&(&1["status"] == "open")) |> Enum.map(& &1["code"])
  end

  test "no resolutions reproduces the engine's issues, all open" do
    result = SalesWorkings.materialize(invoices(), [], @header)

    assert "grand_total_mismatch" in open_codes(result)
    assert "sequence_gaps" in open_codes(result)
    assert result.decisions == %{}
    assert result.silent_errors == []
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "a flagged correction is applied and re-derives" do
    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "20/2026-27",
        "payload" => %{"field" => "printed_grand_total", "from" => 2_75_000.0, "to" => 65_551.36}
      }
    ]

    result = SalesWorkings.materialize(invoices(), resolutions, @header)

    refute "grand_total_mismatch" in open_codes(result)
    assert result.silent_errors == []

    [%{"inv" => derived_invoices}] = result.derived["b2b"]
    assert length(derived_invoices) == 3
  end

  test "a correction to an unflagged field is a silent error, not applied" do
    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "21/2026-27",
        "payload" => %{"field" => "buyer_name", "from" => "PONMANI AND CO", "to" => "MALLORY"}
      }
    ]

    result = SalesWorkings.materialize(invoices(), resolutions, @header)

    assert [%{"field" => "buyer_name"}] = result.silent_errors
    clean = Enum.find(result.invoices, &(&1["invoice_number"] == "21/2026-27"))
    assert clean["buyer_name"] == "PONMANI AND CO"
  end

  test "confirm_issue marks the issue resolved; reopen restores it" do
    result = SalesWorkings.materialize(invoices(), [], @header)
    gap = Enum.find(result.issues, &(&1["code"] == "sequence_gaps"))
    key = SalesWorkings.issue_key(gap)
    confirm = %{"verb" => "confirm_issue", "target" => key, "payload" => %{}}

    confirmed = SalesWorkings.materialize(invoices(), [confirm], @header)
    gap = Enum.find(confirmed.issues, &(&1["code"] == "sequence_gaps"))
    assert gap["status"] == "resolved"

    reopened =
      SalesWorkings.materialize(
        invoices(),
        [confirm, %{"verb" => "reopen", "target" => key, "payload" => %{}}],
        @header
      )

    gap = Enum.find(reopened.issues, &(&1["code"] == "sequence_gaps"))
    assert gap["status"] == "open"
  end

  test "reviewable? once every non-info issue is resolved" do
    result = SalesWorkings.materialize(invoices(), [], @header)

    confirmations =
      result.issues
      |> Enum.reject(&(&1["level"] == "info"))
      |> Enum.map(&%{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(&1)})

    reviewed = SalesWorkings.materialize(invoices(), confirmations, @header)
    assert SalesWorkings.reviewable?(reviewed.issues)
  end

  test "latest correction per field wins; invoice renumbering applies last" do
    # A low-confidence read flags the invoice number, making it correctable.
    invoices =
      invoices()
      |> Enum.map(fn
        %{"invoice_number" => "20/2026-27"} = invoice ->
          Map.put(invoice, "confidence", %{"invoice_number" => 0.3})

        invoice ->
          invoice
      end)

    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "20/2026-27",
        "payload" => %{"field" => "invoice_number", "from" => "20/2026-27", "to" => "19/2026-27"}
      },
      %{
        "verb" => "correct_field",
        "target" => "20/2026-27",
        "payload" => %{"field" => "printed_grand_total", "from" => 2_75_000.0, "to" => 65_551.36}
      }
    ]

    result = SalesWorkings.materialize(invoices, resolutions, @header)

    renamed = Enum.find(result.invoices, &(&1["invoice_number"] == "19/2026-27"))
    assert renamed
    assert renamed["printed_grand_total"] == 65_551.36
    refute "grand_total_mismatch" in open_codes(result)
  end
end
