defmodule Nila.Gst.Sales.WorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Review.CorrectionPolicy
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Hsn.Entry
  alias Nila.Gst.Hsn.Release, as: HsnRelease
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
    |> Enum.map(&Normalizer.normalize/1)
    |> Enum.zip_with(~w(source-a source-b source-c), &Map.put(&1, "id", &2))
  end

  defp raw(page, inum, line_items, grand_total) do
    taxable = line_items |> Enum.map(& &1["printed_taxable_value"]) |> Enum.sum()
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
      "printed_taxable_value" => taxable,
      "cgst_rate" => 9.0,
      "cgst_amount" => side,
      "sgst_rate" => 9.0,
      "sgst_amount" => side
    }
  end

  defp open_codes(result) do
    result.issues |> Enum.filter(&(&1["status"] == "open")) |> Enum.map(& &1["code"])
  end

  test "HSN compliance annotates exact codes and blocks review on an invalid code" do
    directory = %{
      release: %HsnRelease{id: 9},
      entries: %{
        "8415" => %Entry{
          code: "8415",
          kind: "hsn",
          digits: 4,
          description: "Air-conditioning machines"
        }
      },
      prefixes: MapSet.new(~w(8 84 841))
    }

    [first | rest] = invoices()
    first = put_in(first, ["line_items", Access.at(0), "hsn_sac"], "84159999")

    result =
      SalesWorkings.materialize([first | rest], [], @header, [], %{directory: directory})

    assert "invalid_hsn_sac" in open_codes(result)
    refute SalesWorkings.reviewable?(result.issues)

    valid = Enum.find(result.invoices, &(&1["invoice_number"] == "21/2025-26"))

    assert get_in(valid, ["line_items", Access.at(0), "hsn_description"]) ==
             "Air-conditioning machines"
  end

  test "no resolutions reproduces the engine's issues, all open" do
    result = SalesWorkings.materialize(invoices(), [], @header)

    assert "grand_total_mismatch" in open_codes(result)
    assert "sequence_gaps" in open_codes(result)
    assert result.decisions == %{}
    assert result.silent_errors == []
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "an ordinary month raises nothing about cess at all" do
    result = SalesWorkings.materialize(invoices(), [], @header, [])

    refute "cess_unsupported" in open_codes(result)
  end

  test "a tobacco line blocks the return, naming the line and code" do
    result = SalesWorkings.materialize(cess_invoices(), [], @header, [])
    issue = Enum.find(result.issues, &(&1["code"] == "cess_unsupported"))

    assert issue["level"] == "blocking"
    assert SalesWorkings.blocking?(issue)
    assert issue["invoice"] == "24/2025-26"
    assert issue["message"] =~ ~s|Line 1 "Chewing tobacco" is HSN 24039910.|
    assert issue["message"] =~ "csamt 0"
    assert issue["lines"] == [1]
    refute SalesWorkings.reviewable?(result.issues)

    # Nothing to answer: a blocker asks for no work, and that is what blocks.
    assert Nila.Gst.Issues.resolution_kind(issue) == nil
    assert Enum.count(result.issues, &(&1["code"] == "cess_unsupported")) == 1
  end

  # The engine refuses the confirmation itself, not merely the affordance: a
  # sweep that confirms every open target must not clear a supply this return
  # cannot file.
  test "confirming the cess blocker does not clear it" do
    blocker =
      SalesWorkings.materialize(cess_invoices(), [], @header, []).issues
      |> Enum.find(&(&1["code"] == "cess_unsupported"))

    swept =
      SalesWorkings.materialize(cess_invoices(), confirm_everything(), @header, [])

    still = Enum.find(swept.issues, &(&1["code"] == "cess_unsupported"))

    assert blocker["status"] == "open"
    assert still["status"] == "open"
    refute SalesWorkings.reviewable?(swept.issues)
  end

  test "two cess lines on one bill are one blocker naming both" do
    two_lines =
      invoices() ++
        [
          Normalizer.normalize(
            raw(
              4,
              "24/2025-26",
              [
                cess_line("Chewing tobacco", "24039910", 5_000.0),
                line("Delivery", 500.0),
                cess_line("Beedis", "24039920", 1_200.0)
              ],
              8_142.0
            )
          )
        ]

    result = SalesWorkings.materialize(two_lines, [], @header, [])
    blockers = Enum.filter(result.issues, &(&1["code"] == "cess_unsupported"))

    # One row, because one bill is one thing a reviewer works on.
    assert [issue] = blockers
    assert issue["lines"] == [1, 3]
    assert issue["message"] =~ ~s|Line 1 "Chewing tobacco" is HSN 24039910.|
    assert issue["message"] =~ ~s|Line 3 "Beedis" is HSN 24039920.|
  end

  # The only way out of a supply this return cannot carry, now that there is no
  # button asserting it away. Without this the cess issue flags no field, the
  # correction lands in `silent_errors`, and a misread 2403 on an AC bill is a
  # month nobody can file or fix.
  test "a misread cess HSN can be corrected, which clears the blocker" do
    invoices = cess_invoices()
    result = SalesWorkings.materialize(invoices, [], @header, [])

    source_id =
      result.invoices
      |> Enum.find(&(&1["invoice_number"] == "24/2025-26"))
      |> Map.fetch!("id")

    assert CorrectionPolicy.correctable_fields(result.flagged, source_id) == [
             "line_items[0].hsn_sac"
           ]

    correction = %{
      "verb" => "correct_field",
      "target" => source_id,
      "payload" => %{"field" => "line_items[0].hsn_sac", "to" => "8415"}
    }

    fixed = SalesWorkings.materialize(invoices, [correction], @header, [])

    assert fixed.silent_errors == []
    refute "cess_unsupported" in open_codes(fixed)

    corrected_line =
      fixed.active_invoices
      |> Enum.find(&(&1["invoice_number"] == "24/2025-26"))
      |> get_in(["line_items", Access.at(0), "hsn_sac"])

    assert corrected_line == "8415"
  end

  test "a later cess-bearing invoice raises its own blocker" do
    later_invoices =
      cess_invoices() ++
        [
          Normalizer.normalize(
            raw(4, "25/2025-26", [cess_line("Beedis", "24039920", 3_000.0)], 3_540.0)
          )
        ]

    result = SalesWorkings.materialize(later_invoices, [], @header, [])

    blocked =
      result.issues
      |> Enum.filter(&(&1["code"] == "cess_unsupported"))
      |> Enum.map(& &1["invoice"])
      |> Enum.sort()

    # Each bill blocks on its own evidence, not one month-wide verdict.
    assert blocked == ["24/2025-26", "25/2025-26"]
  end

  # One tobacco bill among ordinary ones, which is the shape this screen exists
  # for: a book where cess is the rare exception, not the standing question.
  defp cess_invoices do
    invoices() ++
      [
        Normalizer.normalize(
          raw(4, "24/2025-26", [cess_line("Chewing tobacco", "24039910", 5_000.0)], 5_900.0)
        )
      ]
  end

  defp cess_line(description, hsn, taxable) do
    description |> line(taxable) |> Map.put("hsn_sac", hsn)
  end

  # A sweep that answers every open target, blocker included.
  defp confirm_everything do
    SalesWorkings.materialize(cess_invoices(), [], @header, []).issues
    |> Enum.filter(&(&1["status"] == "open"))
    |> Enum.map(&confirmation/1)
  end

  defp confirmation(issue),
    do: %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)}

  test "legacy unknown line inclusion is re-resolved without mutating stored machine truth" do
    [invoice | _rest] = invoices()

    legacy_line = %{
      "description" => "Condensor Coil",
      "printed_line_amount" => 21_500,
      "printed_taxable_value" => nil,
      "line_amount_tax_inclusion" => "unknown",
      "taxable_value" => nil,
      "taxable_value_basis" => nil,
      "igst_rate" => 18,
      "igst_amount" => 3_870
    }

    pristine =
      invoice
      |> Map.put("invoice_number", "125/2025-26")
      |> Map.put("line_items", [legacy_line])
      |> Map.put("printed_total_tax", 3_870)
      |> Map.put("printed_grand_total", 25_370)

    result = SalesWorkings.materialize([pristine], [], @header)
    [resolved] = result.active_invoices
    [line] = resolved["line_items"]

    assert line["taxable_value"] == 21_500
    assert line["line_amount_tax_inclusion_candidate"] == "unknown"
    assert line["line_amount_tax_inclusion"] == "exclusive"
    assert line["taxable_value_basis"] == "line_amount_times_rate_equals_tax"
    assert get_in(result.derived, ["b2b", Access.at(0), "inv", Access.at(0), "val"]) == 25_370.0

    assert get_in(pristine, ["line_items", Access.at(0), "taxable_value"]) == nil
  end

  test "unresolved taxable evidence blocks and is withheld from the return" do
    [invoice | _rest] = invoices()

    unresolved =
      invoice
      |> Map.put("invoice_number", "UNRESOLVED-1")
      |> Map.put("line_items", [
        %{
          "description" => "Unknown amount basis",
          "printed_line_amount" => 10_000,
          "line_amount_tax_inclusion" => "unknown",
          "taxable_value" => nil,
          "igst_rate" => 18,
          "igst_amount" => nil
        }
      ])

    result = SalesWorkings.materialize([unresolved], [], @header)
    issue = Enum.find(result.issues, &(&1["code"] == "missing_taxable_value"))

    assert issue["level"] == "blocking"
    assert Nila.Gst.Issues.resolution_kind(issue) == :correction
    assert result.derived["b2b"] == []
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "missing tax stays open until its amount is corrected" do
    invoice =
      hd(invoices())
      |> update_in(["line_items", Access.at(0)], fn line ->
        Map.merge(line, %{
          "cgst_rate" => 0,
          "cgst_amount" => 0,
          "sgst_rate" => 0,
          "sgst_amount" => 0,
          "igst_rate" => 18,
          "igst_amount" => nil
        })
      end)

    result = SalesWorkings.materialize([invoice], [], @header)
    issue = Enum.find(result.issues, &(&1["code"] == "missing_tax_amount"))
    assert issue["status"] == "open"

    confirmed = SalesWorkings.materialize([invoice], [confirmation(issue)], @header)
    assert "missing_tax_amount" in open_codes(confirmed)

    correction = %{
      "verb" => "correct_field",
      "target" => invoice["id"],
      "payload" => %{"field" => "line_items[0].igst_amount", "from" => nil, "to" => 9_999.36}
    }

    corrected = SalesWorkings.materialize([invoice], [correction], @header)
    assert corrected.silent_errors == []
    refute "missing_tax_amount" in open_codes(corrected)

    assert get_in(hd(corrected.active_invoices), ["line_items", Access.at(0), "igst_amount"]) ==
             9_999.36
  end

  test "a flagged correction is applied and re-derives" do
    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "source-a",
        "payload" => %{"field" => "printed_grand_total", "from" => 2_75_000.0, "to" => 65_551.36}
      }
    ]

    result = SalesWorkings.materialize(invoices(), resolutions, @header)

    refute "grand_total_mismatch" in open_codes(result)
    assert result.silent_errors == []
    printed = Enum.find(result.printed_active_invoices, &(&1["invoice_number"] == "20/2025-26"))
    assert printed["printed_grand_total"] == 2_75_000.0

    [%{"inv" => derived_invoices}] = result.derived["b2b"]
    assert length(derived_invoices) == 3
  end

  test "a resolution's stated effect equals the actual change in what is filed" do
    # The proposal engine will claim "this files X". That claim is only worth
    # anything if it is measured against `derive/2` rather than predicted
    # alongside it — a second implementation is a second answer.
    alias Nila.Gst.Sales.Review.Values

    before = SalesWorkings.materialize(invoices(), [], @header)

    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "source-a",
        "payload" => %{
          "field" => "line_items[0].taxable_value",
          "from" => 55_552.0,
          "to" => 60_000.0
        }
      }
    ]

    later = SalesWorkings.materialize(invoices(), resolutions, @header)
    effect = Values.effect(before.derived, later.derived)

    # The correction moved one line's taxable value by 4,448, so the return's
    # taxable moves by exactly that and the tax by 18% of it, split two ways.
    assert effect.change.taxable == 4448.0
    assert effect.change.tax == 800.64
    assert effect.change.cgst == 400.32
    assert effect.change.sgst == 400.32

    # And the effect is a reading of the two returns, not a third computation:
    # after minus before, in the figures the portal receives.
    assert effect.after.taxable - effect.before.taxable == effect.change.taxable
    assert Values.filed_totals(later.derived).tax == effect.after.tax
  end

  test "a correction to an unflagged field is a silent error, not applied" do
    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "source-b",
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
        "target" => "source-b",
        "payload" => %{"field" => "ocr_minimum", "from" => nil, "to" => 0.99}
      }
    ]

    result = SalesWorkings.materialize(invoices, resolutions, @header)

    assert MapSet.member?(result.flagged, {"source-b", "ocr_minimum"})
    refute MapSet.member?(result.flagged, {"21/2025-26", "ocr_minimum"})
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
      |> Enum.map(&confirmation/1)

    reviewed = SalesWorkings.materialize(invoices(), confirmations, @header)
    assert SalesWorkings.reviewable?(reviewed.issues)
  end

  test "invoices without IDs receive stable contextual source IDs without mutating machine truth" do
    pristine = Enum.map(invoices(), &Map.delete(&1, "id"))

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

  test "source-targeted correction changes one duplicate while an invoice number changes neither" do
    [invoice | _] = invoices()
    duplicates = [Map.put(invoice, "id", "source-a"), Map.put(invoice, "id", "source-b")]

    number_target = [
      %{
        "verb" => "correct_field",
        "target" => "20/2025-26",
        "payload" => %{"field" => "invoice_number", "from" => "20/2025-26", "to" => "19/2025-26"}
      }
    ]

    number_result = SalesWorkings.materialize(duplicates, number_target, @header)

    assert Enum.map(number_result.active_invoices, & &1["invoice_number"]) == [
             "20/2025-26",
             "20/2025-26"
           ]

    assert length(number_result.silent_errors) == 1

    targeted = put_in(number_target, [Access.at(0), "target"], "source-b")
    targeted_result = SalesWorkings.materialize(duplicates, targeted, @header)

    assert Enum.map(targeted_result.active_invoices, &{&1["id"], &1["invoice_number"]}) == [
             {"source-a", "20/2025-26"},
             {"source-b", "19/2025-26"}
           ]

    refute Enum.any?(targeted_result.issues, &(&1["code"] == "duplicate_invoice_number"))
  end

  test "issue confirmations require the source issue key even for a unique invoice number" do
    [invoice | _] = invoices()
    unique = Map.put(invoice, "id", "source-a")
    target = "20/2025-26:grand_total_mismatch"
    number_confirmation = %{"verb" => "confirm_issue", "target" => target}

    unique_result = SalesWorkings.materialize([unique], [number_confirmation], @header)
    issue = Enum.find(unique_result.issues, &(&1["code"] == "grand_total_mismatch"))
    assert issue["status"] == "open"

    exact_result = SalesWorkings.materialize([unique], [confirmation(issue)], @header)
    exact_issue = Enum.find(exact_result.issues, &(&1["code"] == "grand_total_mismatch"))
    assert exact_issue["status"] == "resolved"

    duplicates = [unique, Map.put(unique, "id", "source-b")]
    duplicate_result = SalesWorkings.materialize(duplicates, [number_confirmation], @header)

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
          "target" => "duplicate_copy|#{id}",
          "payload" => %{
            "excluded_source_id" => id,
            "retained_source_id" => "source-a",
            "reason" => "same scan uploaded twice",
            "outcome" => "same_invoice_uploaded_twice"
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
               "excluded_source_id" => copy["id"],
               "retained_source_id" => "source-a",
               "reason" => "same scan uploaded twice",
               "outcome" => "same_invoice_uploaded_twice"
             }
           end)

    refute Enum.any?(excluded.issues, &(&1["code"] == "duplicate_invoice_number"))

    reopened =
      SalesWorkings.materialize(
        sources,
        exclusions ++
          [%{"verb" => "reopen", "target" => "duplicate_copy|source-c", "payload" => %{}}],
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
        "target" => "source-a",
        "payload" => %{"field" => "invoice_number", "from" => "20/2025-26", "to" => "19/2025-26"}
      },
      %{
        "verb" => "correct_field",
        "target" => "source-a",
        "payload" => %{"field" => "printed_grand_total", "from" => 2_75_000.0, "to" => 65_551.36}
      }
    ]

    result = SalesWorkings.materialize(invoices, resolutions, @header)

    renamed = Enum.find(result.invoices, &(&1["invoice_number"] == "19/2025-26"))
    assert renamed
    assert renamed["printed_grand_total"] == 65_551.36
    refute "grand_total_mismatch" in open_codes(result)
  end

  test "a blocker sorts above the routine checks it would otherwise hide behind" do
    [first | rest] = invoices()
    duplicate = Map.put(first, "id", "source-duplicate")

    result = SalesWorkings.materialize([first, duplicate | rest], [], @header)

    assert hd(result.issues)["code"] == "duplicate_invoice_number"

    levels = result.issues |> Enum.map(&Nila.Gst.Issues.level/1) |> Enum.uniq()
    assert levels == Enum.filter(~w(blocking required advisory info), &(&1 in levels))

    # Within a level, the work a reviewer can only do with the bill in hand
    # comes before the attestations that ride on it.
    kinds =
      result.issues
      |> Enum.filter(&(Nila.Gst.Issues.level(&1) == "required"))
      |> Enum.map(&Nila.Gst.Issues.resolution_kind/1)
      |> Enum.uniq()

    assert kinds == Enum.filter([:correction, :decision, :confirmation], &(&1 in kinds))
  end

  test "issues sharing one resolution target render once, carrying every message" do
    ledger =
      for source <- ~w(october-scan-1.pdf october-scan-2.pdf) do
        %{
          "invoice" => nil,
          "code" => "pages_unaccounted",
          "level" => "required",
          "message" => "pages 3 of #{source} produced no invoice.",
          "fields" => ["doc_issue"]
        }
      end

    result = SalesWorkings.materialize(invoices(), [], @header, ledger)

    assert [issue] = Enum.filter(result.issues, &(&1["code"] == "pages_unaccounted"))
    assert issue["message"] =~ "october-scan-1.pdf"
    assert issue["message"] =~ "october-scan-2.pdf"

    # And one answer settles it, because there was only ever one target.
    answered =
      SalesWorkings.materialize(invoices(), [confirmation(issue)], @header, ledger)

    assert [%{"status" => "resolved"}] =
             Enum.filter(answered.issues, &(&1["code"] == "pages_unaccounted"))
  end

  # Two rounding differences on one bill share a key precisely because neither
  # is ever answered. Merging them would lose a fact and settle nothing.
  test "settled observations that share a key stay distinct" do
    line = %{
      "description" => "Service",
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
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
          "line_items" => List.duplicate(line, 4)
        }
      })

    result = SalesWorkings.materialize([invoice], [], @header)

    assert Enum.count(result.issues, &(&1["code"] == "rounding_variance")) == 2
  end
end
