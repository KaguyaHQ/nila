defmodule Nila.Gst.Sales.WorkingsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Hsn.Entry
  alias Nila.Gst.Hsn.Release, as: HsnRelease
  alias Nila.Gst.Rates.Release, as: RateRelease
  alias Nila.Gst.Rates.Rule, as: RateRule
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

  test "statutory candidate mismatch enters the normal resolvable review queue" do
    hsn_directory = %{
      release: %HsnRelease{id: 9},
      entries: %{
        "8415" => %Entry{code: "8415", kind: "hsn", digits: 4, description: "Machines"}
      },
      prefixes: MapSet.new(~w(8 84 841))
    }

    rate_directory = %{
      release: %RateRelease{
        id: 10,
        notification_number: "9/2025-Integrated Tax (Rate)",
        effective_from: ~D[2025-09-22]
      },
      rules: [
        %RateRule{
          serial_number: 1,
          schedule: "I",
          total_rate: Decimal.new("5"),
          raw_code_expression: "8415",
          raw_description: "Machines",
          parsed_scope: %{
            "includes" => ["8415"],
            "excludes" => [],
            "ranges" => [],
            "any_chapter" => false
          },
          parser_confidence: "automatic"
        }
      ]
    }

    result =
      SalesWorkings.materialize(invoices(), [], @header, [], %{
        directory: hsn_directory,
        rate_directory: rate_directory
      })

    assert "statutory_rate_mismatch" in open_codes(result)
    refute SalesWorkings.reviewable?(result.issues)

    assert get_in(hd(result.invoices), [
             "line_items",
             Access.at(0),
             "rate_validation",
             "status"
           ]) == "incompatible"
  end

  test "no resolutions reproduces the engine's issues, all open" do
    result = SalesWorkings.materialize(invoices(), [], @header)

    assert "grand_total_mismatch" in open_codes(result)
    assert "sequence_gaps" in open_codes(result)
    assert result.decisions == %{}
    assert result.silent_errors == []
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "an unseen HSN code is context, and does not withhold the filing" do
    directory = %{
      release: %HsnRelease{id: 9},
      entries: %{
        "8415" => %Entry{code: "8415", kind: "hsn", digits: 4, description: "Machines"}
      },
      prefixes: MapSet.new(~w(8 84 841))
    }

    # A month whose codes this client has never filed before, and nothing else
    # wrong: no check asserts an error, so novelty alone must not gate.
    history = [%{code: "9999", rate: 18.0, description: "something else", key: {"9999", "x"}}]

    result =
      SalesWorkings.materialize(invoices(), [], @header, [], %{
        directory: directory,
        rate_history: history
      })

    novelty = Enum.filter(result.issues, &(&1["code"] == "hsn_new_code"))

    assert novelty != []
    assert Enum.all?(novelty, &(&1["level"] == "advisory"))
    refute Enum.any?(novelty, &Nila.Gst.Issues.gating?/1)

    confirmations =
      result.issues
      |> Enum.filter(&(&1["status"] == "open" and Nila.Gst.Issues.gating?(&1)))
      |> Enum.map(&%{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(&1)})

    answered =
      SalesWorkings.materialize(invoices(), confirmations, @header, [], %{
        directory: directory,
        rate_history: history
      })

    assert "hsn_new_code" in open_codes(answered)
    assert SalesWorkings.reviewable?(answered.issues)
  end

  test "cess not evaluated is a question the reviewer can answer" do
    result = SalesWorkings.materialize(invoices(), [], @header, [], cess_evaluated: false)
    issue = Enum.find(result.issues, &(&1["code"] == "cess_not_evaluated"))

    assert issue["level"] == "required"
    assert Nila.Gst.Issues.resolution_kind(issue) == :confirmation
    assert issue["message"] =~ "Cess has not been checked on 3 sales invoices"
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "confirming no cess applies clears the question" do
    target = cess_target(invoices())

    resolutions =
      confirm_all_but_cess() ++
        [
          %{
            "verb" => "confirm_issue",
            "target" => target,
            "payload" => %{"answer" => "no_cess"}
          }
        ]

    result =
      SalesWorkings.materialize(invoices(), resolutions, @header, [], cess_evaluated: false)

    refute "cess_not_evaluated" in open_codes(result)
    refute "cess_unsupported" in open_codes(result)
    assert SalesWorkings.reviewable?(result.issues)
  end

  test "answering that cess applies uncovers a blocking capability gap" do
    target = cess_target(invoices())

    resolutions =
      confirm_all_but_cess() ++
        [
          %{
            "verb" => "confirm_issue",
            "target" => target,
            "payload" => %{"answer" => "cess_applies"}
          }
        ]

    result =
      SalesWorkings.materialize(invoices(), resolutions, @header, [], cess_evaluated: false)

    blocker = Enum.find(result.issues, &(&1["code"] == "cess_unsupported"))

    # The question is answered; what the answer uncovered is not confirmable.
    refute "cess_not_evaluated" in open_codes(result)
    assert blocker["level"] == "blocking"
    assert blocker["status"] == "open"
    assert SalesWorkings.blocking?(blocker)
    refute SalesWorkings.reviewable?(result.issues)
  end

  test "reopening the cess target discards the answer and the derived blocker" do
    target = cess_target(invoices())

    resolutions = [
      %{
        "verb" => "confirm_issue",
        "target" => target,
        "payload" => %{"answer" => "cess_applies"}
      },
      %{"verb" => "reopen", "target" => target}
    ]

    result =
      SalesWorkings.materialize(invoices(), resolutions, @header, [], cess_evaluated: false)

    assert "cess_not_evaluated" in open_codes(result)
    refute Enum.any?(result.issues, &(&1["code"] == "cess_unsupported"))
  end

  test "a later invoice invalidates a cess answer given over the earlier set" do
    answered_set = invoices()

    resolutions = [
      %{
        "verb" => "confirm_issue",
        "target" => cess_target(answered_set),
        "payload" => %{"answer" => "no_cess"}
      }
    ]

    ninth =
      Gstr1.normalize_invoice(raw(4, "24/2025-26", [line("Compressor", 8_000.0)], 9_440.0))

    later =
      SalesWorkings.materialize(answered_set ++ [ninth], resolutions, @header, [],
        cess_evaluated: false
      )

    assert "cess_not_evaluated" in open_codes(later)

    assert Enum.find(later.issues, &(&1["code"] == "cess_not_evaluated"))["message"] =~
             "4 sales invoices"
  end

  test "replacing an invoice invalidates a cess answer, even at the same source ID" do
    answered_set = invoices()

    resolutions = [
      %{
        "verb" => "confirm_issue",
        "target" => cess_target(answered_set),
        "payload" => %{"answer" => "no_cess"}
      }
    ]

    # Source IDs are positional, so a re-extraction that swaps the third bill
    # hands the replacement the same ID the answered one had.
    replaced =
      List.replace_at(
        answered_set,
        2,
        Gstr1.normalize_invoice(raw(3, "99/2025-26", [line("Chiller", 4_000.0)], 4_720.0))
      )

    result =
      SalesWorkings.materialize(replaced, resolutions, @header, [], cess_evaluated: false)

    assert "cess_not_evaluated" in open_codes(result)
  end

  # The target as a surface reads it: off the issue the engine raised, never
  # recomputed — a caller that rebuilt the key would not notice it drifting.
  defp cess_target(invoices) do
    SalesWorkings.materialize(invoices, [], @header, [], cess_evaluated: false).issues
    |> Enum.find(&(&1["code"] == "cess_not_evaluated"))
    |> Map.fetch!("target")
  end

  # Everything the fixture raises other than the cess question, so a test about
  # cess reads `reviewable?` for the cess answer alone.
  defp confirm_all_but_cess do
    SalesWorkings.materialize(invoices(), [], @header, [], cess_evaluated: false).issues
    |> Enum.filter(&(&1["status"] == "open" and &1["code"] != "cess_not_evaluated"))
    |> Enum.map(&%{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(&1)})
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
    printed = Enum.find(result.printed_active_invoices, &(&1["invoice_number"] == "20/2025-26"))
    assert printed["printed_grand_total"] == 2_75_000.0

    [%{"inv" => derived_invoices}] = result.derived["b2b"]
    assert length(derived_invoices) == 3
  end

  test "a resolution's stated effect equals the actual change in what is filed" do
    # The proposal engine will claim "this files X". That claim is only worth
    # anything if it is measured against `derive/2` rather than predicted
    # alongside it — a second implementation is a second answer.
    alias Nila.Gst.Sales.Values

    before = SalesWorkings.materialize(invoices(), [], @header)

    resolutions = [
      %{
        "verb" => "correct_field",
        "target" => "20/2025-26",
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
