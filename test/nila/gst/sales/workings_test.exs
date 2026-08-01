defmodule Nila.Gst.Sales.WorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  @header Gstr1.production_header("33AEWPH4158J1Z3", "2025-10")

  # Stub-shaped raw pages run through the real normalizer, so these tests
  # exercise the same invoice shape production stores in sales_months.
  defp invoices do
    [
      # Poison total: printed grand total disagrees with line sum.
      raw(1, "20/2025-26", [line("Refrigeration unit", 55_552.0)], 2_75_000.0),
      raw(2, "21/2025-26", [line("AC service", 12_000.0)], 14_160.0),
      # Sequence gap: 22 is missing, 23 follows.
      raw(3, "23/2025-26", [line("134A Gas", 10_200.0)], 12_036.0)
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
        "invoice_date" => "08.10.2025",
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
        "target" => "20/2025-26",
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
        "target" => "21/2025-26",
        "payload" => %{"field" => "buyer_name", "from" => "PONMANI AND CO", "to" => "MALLORY"}
      }
    ]

    result = SalesWorkings.materialize(invoices(), resolutions, @header)

    assert [%{"field" => "buyer_name"}] = result.silent_errors
    clean = Enum.find(result.invoices, &(&1["invoice_number"] == "21/2025-26"))
    assert clean["buyer_name"] == "PONMANI AND CO"
  end

  test "low OCR metadata is flagged but cannot be corrected" do
    invoices =
      Enum.map(invoices(), fn
        %{"invoice_number" => "21/2025-26"} = invoice ->
          Map.put(invoice, "confidence", %{"ocr_minimum" => 0.42})

        invoice ->
          invoice
      end)

    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "21/2025-26",
        "payload" => %{"field" => "ocr_minimum", "from" => nil, "to" => 0.99}
      }
    ]

    result = SalesWorkings.materialize(invoices, resolutions, @header)

    assert MapSet.member?(result.flagged, {"21/2025-26", "ocr_minimum"})
    assert [%{"field" => "ocr_minimum"}] = result.silent_errors
    clean = Enum.find(result.invoices, &(&1["invoice_number"] == "21/2025-26"))
    refute Map.has_key?(clean, "ocr_minimum")
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

  test "legacy invoices receive stable contextual source IDs without mutating machine truth" do
    pristine = invoices()

    first =
      SalesWorkings.materialize(pristine, [], @header, [], source_namespace: "sales_month_42")

    second =
      SalesWorkings.materialize(pristine, [], @header, [], source_namespace: "sales_month_42")

    assert Enum.map(first.source_invoices, & &1["id"]) ==
             ~w(sales_month_42_inv_01 sales_month_42_inv_02 sales_month_42_inv_03)

    assert Enum.map(second.source_invoices, & &1["id"]) ==
             Enum.map(first.source_invoices, & &1["id"])

    refute Enum.any?(pristine, &Map.has_key?(&1, "id"))
  end

  test "duplicate-number blocker identifies every source and cannot be confirmed away" do
    duplicate =
      invoices()
      |> Enum.at(1)
      |> Map.put("id", "source-b")

    original = Map.put(duplicate, "id", "source-a")
    result = SalesWorkings.materialize([original, duplicate], [], @header)

    issue = Enum.find(result.issues, &(&1["code"] == "duplicate_invoice_number"))
    assert issue["source_ids"] == ["source-a", "source-b"]
    assert issue["target"] =~ "duplicate_invoice_number|21/2025-26|"
    assert issue["status"] == "open"
    refute SalesWorkings.reviewable?(result.issues)

    confirmed =
      SalesWorkings.materialize(
        [original, duplicate],
        [%{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)}],
        @header
      )

    issue = Enum.find(confirmed.issues, &(&1["code"] == "duplicate_invoice_number"))
    assert issue["status"] == "open"
  end

  test "source-targeted correction changes one duplicate while a legacy target changes neither" do
    [invoice | _] = invoices()
    duplicates = [Map.put(invoice, "id", "source-a"), Map.put(invoice, "id", "source-b")]

    legacy = [
      %{
        "verb" => "correct_field",
        "target" => "20/2025-26",
        "payload" => %{"field" => "invoice_number", "from" => "20/2025-26", "to" => "19/2025-26"}
      }
    ]

    legacy_result = SalesWorkings.materialize(duplicates, legacy, @header)

    assert Enum.map(legacy_result.active_invoices, & &1["invoice_number"]) == [
             "20/2025-26",
             "20/2025-26"
           ]

    assert length(legacy_result.silent_errors) == 1

    targeted = put_in(legacy, [Access.at(0), "target"], "source-b")
    targeted_result = SalesWorkings.materialize(duplicates, targeted, @header)

    assert Enum.map(targeted_result.active_invoices, &{&1["id"], &1["invoice_number"]}) == [
             {"source-a", "20/2025-26"},
             {"source-b", "19/2025-26"}
           ]

    refute Enum.any?(targeted_result.issues, &(&1["code"] == "duplicate_invoice_number"))
  end

  test "legacy issue confirmations replay only for a unique invoice number" do
    [invoice | _] = invoices()
    unique = Map.put(invoice, "id", "source-a")
    target = "20/2025-26:grand_total_mismatch"
    confirmation = %{"verb" => "confirm_issue", "target" => target}

    unique_result = SalesWorkings.materialize([unique], [confirmation], @header)
    issue = Enum.find(unique_result.issues, &(&1["code"] == "grand_total_mismatch"))
    assert issue["status"] == "resolved"

    duplicates = [unique, Map.put(unique, "id", "source-b")]
    duplicate_result = SalesWorkings.materialize(duplicates, [confirmation], @header)

    assert duplicate_result.issues
           |> Enum.filter(&(&1["code"] == "grand_total_mismatch"))
           |> Enum.all?(&(&1["status"] == "open"))
  end

  test "excluding two copies from a group of three preserves all sources and reopen restores one" do
    invoice = invoices() |> Enum.at(1)

    sources =
      for id <- ~w(source-a source-b source-c), do: Map.put(invoice, "id", id)

    exclusions =
      for id <- ~w(source-b source-c) do
        %{
          "verb" => "exclude_duplicate_copy",
          "target" => id,
          "payload" => %{
            "retained_source_id" => "source-a",
            "reason" => "same scan uploaded twice",
            "outcome" => "excluded_duplicate_copy"
          }
        }
      end

    excluded = SalesWorkings.materialize(sources, exclusions, @header)

    assert length(excluded.source_invoices) == 3
    assert Enum.map(excluded.active_invoices, & &1["id"]) == ["source-a"]
    assert Enum.map(excluded.duplicate_copies, & &1["id"]) == ["source-b", "source-c"]

    assert Enum.all?(excluded.duplicate_copies, fn copy ->
             copy["duplicate_copy"] == %{
               "excluded" => true,
               "retained_source_id" => "source-a",
               "reason" => "same scan uploaded twice",
               "outcome" => "excluded_duplicate_copy"
             }
           end)

    refute Enum.any?(excluded.issues, &(&1["code"] == "duplicate_invoice_number"))

    reopened =
      SalesWorkings.materialize(
        sources,
        exclusions ++ [%{"verb" => "reopen", "target" => "source-c", "payload" => %{}}],
        @header
      )

    assert Enum.map(reopened.active_invoices, & &1["id"]) == ["source-a", "source-c"]
    assert Enum.map(reopened.duplicate_copies, & &1["id"]) == ["source-b"]

    assert Enum.any?(reopened.issues, fn issue ->
             issue["code"] == "duplicate_invoice_number" and
               issue["source_ids"] == ["source-a", "source-c"]
           end)
  end

  test "latest correction per field wins; invoice renumbering applies last" do
    # A low-confidence read flags the invoice number, making it correctable.
    invoices =
      invoices()
      |> Enum.map(fn
        %{"invoice_number" => "20/2025-26"} = invoice ->
          Map.put(invoice, "confidence", %{"invoice_number" => 0.3})

        invoice ->
          invoice
      end)

    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "20/2025-26",
        "payload" => %{"field" => "invoice_number", "from" => "20/2025-26", "to" => "19/2025-26"}
      },
      %{
        "verb" => "correct_field",
        "target" => "20/2025-26",
        "payload" => %{"field" => "printed_grand_total", "from" => 2_75_000.0, "to" => 65_551.36}
      }
    ]

    result = SalesWorkings.materialize(invoices, resolutions, @header)

    renamed = Enum.find(result.invoices, &(&1["invoice_number"] == "19/2025-26"))
    assert renamed
    assert renamed["printed_grand_total"] == 65_551.36
    refute "grand_total_mismatch" in open_codes(result)
  end
end
