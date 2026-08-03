defmodule Nila.Gst.Sales.Gstr1Test do
  @moduledoc """
  Unit + reproduction tests for the GSTR-1 derivation engine.

  Everything here is self-contained and runs on any checkout. Scoring the real
  corpus is `mix nila.eval score`, whose numbers live in run records that carry
  the extractor, model and prompt fingerprint that produced them — a test
  asserting a corpus score would either skip (reading as a pass) or freeze a
  number nobody can attribute.
  """
  use ExUnit.Case, async: true

  alias Nila.Eval.Gstr1Diff
  alias Nila.Gst.Sales.Gstr1

  describe "valid_gstin?/1" do
    test "accepts real GSTINs and rejects checksum-broken ones" do
      assert Gstr1.valid_gstin?("33AEWPH4158J1Z3")
      assert Gstr1.valid_gstin?("33BPBPK1081A1ZO")
      refute Gstr1.valid_gstin?("33AEWPH4158J1Z4")
      refute Gstr1.valid_gstin?("garbage")
      refute Gstr1.valid_gstin?(nil)
    end
  end

  describe "normalize_invoice/1" do
    test "drops degenerate lines and lifts nested seller/buyer" do
      raw = %{
        "page" => 1,
        "data" => %{
          "invoice_number" => " 20 / 2026-27 ",
          "invoice_date" => "04.05.2026",
          "seller" => %{"name" => "S", "gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "B", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{"taxable_value" => 1000, "cgst_amount" => 90, "sgst_amount" => 90},
            %{"taxable_value" => 0, "quantity" => 0}
          ]
        }
      }

      invoice = Gstr1.normalize_invoice(raw)
      assert invoice["invoice_number"] == "20/2026-27"
      assert invoice["seller_gstin"] == "33AEWPH4158J1Z3"
      assert length(invoice["line_items"]) == 1
    end

    # Parsed here so every kind of packet carries the same type downstream and a
    # check written once covers all of them — the gap that let a June sales
    # packet file itself into December unremarked.
    test "parses printed dates in every shape the packets arrive in" do
      for printed <- ["04.05.2026", "04/05/2026", "04-05-2026", "2026-05-04", "4/5/26"] do
        assert dated(printed)["invoice_date"] == ~D[2026-05-04], "failed on #{printed}"
      end
    end

    test "a date nothing can read keeps its printed text rather than becoming nil" do
      assert dated("Invoice Dt.")["invoice_date"] == "Invoice Dt."
      assert dated(nil)["invoice_date"] == nil
    end
  end

  describe "validation_issues/1 — the date that reaches the portal unchecked" do
    test "an unreadable date is raised as a correctable issue" do
      issues = Gstr1.validation_issues([dated("Invoice Dt.")])
      assert issue = Enum.find(issues, &(&1["code"] == "unreadable_invoice_date"))
      assert "invoice_date" in issue["fields"]
    end

    test "a date that parsed is not an issue" do
      codes = Gstr1.validation_issues([dated("04.05.2026")]) |> Enum.map(& &1["code"])
      refute "unreadable_invoice_date" in codes
    end

    # The provider schemas ask for a string; that is a request, not a guarantee.
    # A bare number files as `idt: "20260504"` and is invisible to the period
    # checks too, so it has to be caught here or nowhere.
    test "a date that is not even text is caught" do
      codes = Gstr1.validation_issues([dated(20_260_504)]) |> Enum.map(& &1["code"])
      assert "unreadable_invoice_date" in codes
    end

    test "an invoice carrying values but no date is asked for one" do
      for empty <- [nil, "", "   "] do
        issue = Gstr1.validation_issues([dated(empty)]) |> Enum.find(&date_issue?/1)
        assert issue, "stayed quiet on #{inspect(empty)}"
        assert issue["message"] =~ "no invoice date was extracted"
      end
    end

    # Same gate `invoice_number_issues/1` uses. A caption scraped off a page
    # header is not a bill, and flagging it is noise in the reviewer's queue.
    test "a furniture row with no values is not asked about its date" do
      furniture =
        Gstr1.normalize_invoice(%{
          "page" => 1,
          "data" => %{
            "invoice_number" => nil,
            "invoice_date" => "Invoice Dt.",
            "line_items" => []
          }
        })

      refute Enum.any?(Gstr1.validation_issues([furniture]), &date_issue?/1)
    end
  end

  describe "derive/2 — the portal's date format" do
    # `idt` is DD-MM-YYYY. Swapping separators on whatever the model printed only
    # produced that by luck: an ISO date came out ISO and was filed that way.
    test "renders idt as DD-MM-YYYY whatever the bill printed" do
      for printed <- ["2026-05-04", "04/05/2026", "4.5.2026"] do
        assert idt(printed) == "04-05-2026", "failed on #{printed}"
      end
    end
  end

  defp date_issue?(issue), do: issue["code"] == "unreadable_invoice_date"

  defp dated(printed) do
    Gstr1.normalize_invoice(%{
      "page" => 1,
      "data" => %{
        "invoice_number" => "20/2026-27",
        "invoice_date" => printed,
        "seller" => %{"name" => "S", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "B", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          %{"taxable_value" => 1000, "cgst_rate" => 9, "cgst_amount" => 90, "sgst_amount" => 90}
        ],
        "printed_grand_total" => 1180.0
      }
    })
  end

  defp idt(printed) do
    %{"b2b" => [%{"inv" => [inv | _rest]} | _more]} =
      Gstr1.derive([dated(printed)], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

    inv["idt"]
  end

  describe "validation_issues/1 — the poison-total canary" do
    test "raises grand_total_mismatch when printed total disagrees with line sums" do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "20/2026-27",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{"taxable_value" => 64_552, "cgst_amount" => 5809.68, "sgst_amount" => 5809.68}
            ],
            "printed_grand_total" => 2_75_000.00
          }
        })

      codes = Gstr1.validation_issues([invoice]) |> Enum.map(& &1["code"])
      assert "grand_total_mismatch" in codes
    end

    test "flags implausible invoice numbers as correctable issues" do
      suspicious = seq_invoice("9381153296")
      ordinary = seq_invoice("INV-2025/046")

      issues = Gstr1.validation_issues([suspicious, ordinary])

      assert Enum.any?(issues, fn issue ->
               issue["invoice"] == "9381153296" and
                 issue["code"] == "implausible_invoice_number" and
                 issue["fields"] == ["invoice_number"]
             end)

      refute Enum.any?(issues, fn issue ->
               issue["invoice"] == "INV-2025/046" and
                 issue["code"] == "implausible_invoice_number"
             end)

      flagged = Gstr1.flagged_fields([suspicious, ordinary], issues)
      assert MapSet.member?(flagged, {"9381153296", "invoice_number"})
    end

    test "flags sequence gaps from the observed invoice numbers" do
      invoices =
        for n <- [20, 21, 23], do: seq_invoice("#{n}/2026-27")

      codes = Gstr1.validation_issues(invoices) |> Enum.map(& &1["code"])
      assert "sequence_gaps" in codes
    end
  end

  describe "invoice_checks/1 — outcomes with issues as the failing subset" do
    test "a clean invoice passes its checks with the operands to print" do
      invoice = seq_invoice("20/2026-27")

      checks = Gstr1.invoice_checks(invoice)

      line = Enum.find(checks, &(&1["code"] == "line_arithmetic"))
      assert line["passed"] == true
      assert line["operands"]["taxable"] == 1000
      assert line["operands"]["rate"] == 18
      assert line["operands"]["actual"] == 180

      split = Enum.find(checks, &(&1["code"] == "cgst_sgst_unequal"))
      assert split["passed"] == true
    end

    test "the failing subset is exactly the arithmetic issues raised" do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "20/2026-27",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{
                "taxable_value" => 1000,
                "cgst_rate" => 9,
                "cgst_amount" => 90,
                "sgst_rate" => 9,
                "sgst_amount" => 90
              }
            ],
            "printed_total_taxable" => 1000,
            "printed_total_tax" => 180,
            "printed_grand_total" => 9999
          }
        })

      failed =
        invoice
        |> Gstr1.invoice_checks()
        |> Enum.reject(& &1["passed"])
        |> MapSet.new(&{&1["code"], &1["fields"]})

      check_codes =
        ~w(line_arithmetic cgst_sgst_unequal printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

      raised =
        [invoice]
        |> Gstr1.validation_issues()
        |> Enum.filter(&(&1["code"] in check_codes))
        |> MapSet.new(&{&1["code"], &1["fields"]})

      assert failed == raised

      assert MapSet.member?(
               failed,
               {"grand_total_mismatch", ["printed_grand_total", "line_items"]}
             )
    end

    test "unequal halves fail even when their sum still multiplies out" do
      invoice = %{
        "invoice_number" => "20/2026-27",
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 100,
            "sgst_rate" => 9,
            "sgst_amount" => 80
          }
        ]
      }

      checks = Gstr1.invoice_checks(invoice)

      assert %{"passed" => true} = Enum.find(checks, &(&1["code"] == "line_arithmetic"))
      assert %{"passed" => false} = Enum.find(checks, &(&1["code"] == "cgst_sgst_unequal"))

      codes = Gstr1.validation_issues([invoice]) |> Enum.map(& &1["code"])
      assert "cgst_sgst_unequal" in codes
    end

    test "a row claiming nothing and an absent printed total yield no outcome" do
      invoice = %{
        "invoice_number" => "20/2026-27",
        "line_items" => [%{"description" => "page furniture"}]
      }

      assert Gstr1.invoice_checks(invoice) == []
    end
  end

  describe "series_account/1 — the account's series statement" do
    test "bounds the run and names gaps and duplicates with the series suffix" do
      invoices = for n <- [20, 21, 21, 23], do: seq_invoice("#{n}/2026-27")

      account = Gstr1.series_account(invoices)

      assert account.from == "20/2026-27"
      assert account.to == "23/2026-27"
      assert account.missing == ["22/2026-27"]
      assert account.duplicates == ["21/2026-27"]
    end

    test "a complete series has nothing to confess" do
      invoices = for n <- [20, 21, 22], do: seq_invoice("#{n}/2026-27")

      assert %{missing: [], duplicates: []} = Gstr1.series_account(invoices)
    end

    test "no parseable invoice numbers means no statement, not a crash" do
      assert Gstr1.series_account([]) == nil
      assert Gstr1.series_account([seq_invoice(nil)]) == nil
    end

    test "names exactly the gaps the sequence_gaps issue is raised from" do
      invoices = for n <- [20, 23], do: seq_invoice("#{n}/2026-27")

      %{missing: missing} = Gstr1.series_account(invoices)

      [issue] = Enum.filter(Gstr1.validation_issues(invoices), &(&1["code"] == "sequence_gaps"))

      assert missing == ["21/2026-27", "22/2026-27"]
      assert issue["message"] =~ Enum.join(missing, ", ")
    end
  end

  describe "apply_corrections/3 — silent-error discipline" do
    setup do
      invoice = seq_invoice("20/2026-27")
      flagged = Gstr1.flagged_fields([invoice], [])
      %{invoice: invoice, flagged: flagged}
    end

    test "a correction to an unflagged field is a silent error", %{
      invoice: invoice,
      flagged: flagged
    } do
      corrections = [%{"invoice" => "20/2026-27", "field" => "buyer_name", "value" => "X"}]
      {_final, ok, silent, _} = Gstr1.apply_corrections([invoice], corrections, flagged)
      assert ok == []
      assert length(silent) == 1
    end

    test "a source-targeted correction changes only that duplicate" do
      duplicates = [
        seq_invoice("20/2026-27") |> Map.put("id", "source-a"),
        seq_invoice("20/2026-27") |> Map.put("id", "source-b")
      ]

      flagged = MapSet.new([{"source-b", "invoice_number"}])

      correction = %{
        "source_id" => "source-b",
        "field" => "invoice_number",
        "value" => "21/2026-27"
      }

      {final, [^correction], [], _} = Gstr1.apply_corrections(duplicates, [correction], flagged)

      assert Enum.map(final, &{&1["id"], &1["invoice_number"]}) == [
               {"source-a", "20/2026-27"},
               {"source-b", "21/2026-27"}
             ]
    end

    test "a legacy correction does not fan out across duplicate numbers" do
      duplicates = [
        seq_invoice("20/2026-27") |> Map.put("id", "source-a"),
        seq_invoice("20/2026-27") |> Map.put("id", "source-b")
      ]

      correction = %{
        "invoice" => "20/2026-27",
        "field" => "invoice_number",
        "value" => "21/2026-27"
      }

      flagged = MapSet.new([{"source-a", "invoice_number"}, {"source-b", "invoice_number"}])

      {final, [], [^correction], _} = Gstr1.apply_corrections(duplicates, [correction], flagged)
      assert Enum.map(final, & &1["invoice_number"]) == ["20/2026-27", "20/2026-27"]
    end

    test "a correction to a flagged field is legitimate", %{invoice: invoice} do
      flagged =
        Gstr1.flagged_fields([invoice], [
          %{"invoice" => "20/2026-27", "code" => "x", "fields" => ["buyer_name"]}
        ])

      corrections = [%{"invoice" => "20/2026-27", "field" => "buyer_name", "value" => "X"}]
      {_final, ok, silent, _} = Gstr1.apply_corrections([invoice], corrections, flagged)
      assert length(ok) == 1
      assert silent == []
    end

    test "OCR metadata cannot authorize a correction", %{invoice: invoice} do
      flagged = MapSet.new([{"20/2026-27", "ocr_minimum"}])
      correction = %{"invoice" => "20/2026-27", "field" => "ocr_minimum", "value" => 0.99}

      {_final, ok, silent, _} = Gstr1.apply_corrections([invoice], [correction], flagged)

      assert ok == []
      assert silent == [correction]
    end
  end

  describe "derive/2 — empty domain" do
    test "zero invoices returns an empty-but-valid return, not a crash" do
      result = Gstr1.derive([], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

      assert result["gstin"] == "33AEWPH4158J1Z3"
      assert result["b2b"] == []
      assert result["doc_issue"] == %{"doc_det" => []}
      assert result["hsn"] == %{"hsn_b2b" => [], "hsn_b2c" => []}
    end

    test "invoices with no parseable numbers yield an empty doc_issue" do
      invoice = %{"invoice_number" => nil, "buyer_gstin" => "33AABCP9487A1ZG", "line_items" => []}
      result = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "052026"})

      assert result["doc_issue"] == %{"doc_det" => []}
    end
  end

  describe "review correction helpers" do
    test "returns only sorted scalar fields for the pristine invoice number" do
      flagged =
        MapSet.new([
          {"INV-1", "seller_name"},
          {"INV-1", "line_items[0].taxable_value"},
          {"INV-1", "line_items"},
          {"INV-1", "doc_issue"},
          {"INV-1", "line_items[0].confidence"},
          {"INV-1", "ocr_minimum"},
          {"INV-1", "ocr_average"},
          {"INV-1", "unknown_metadata"},
          {"INV-2", "buyer_name"}
        ])

      assert Gstr1.correctable_fields(flagged, "INV-1") == [
               "line_items[0].taxable_value",
               "seller_name"
             ]
    end

    test "reads scalar and indexed line-item field paths" do
      invoice = %{
        "invoice_number" => "1234",
        "line_items" => [%{"taxable_value" => 125.5}]
      }

      assert Gstr1.field_value(invoice, "invoice_number") == "1234"
      assert Gstr1.field_value(invoice, "line_items[0].taxable_value") == 125.5
      assert Gstr1.field_value(invoice, "line_items[9].taxable_value") == nil
    end

    test "coerces only the existing numeric field set and leaves invoice numbers as strings" do
      assert Gstr1.coerce_correction("printed_total_taxable", "100.25") == 100.25
      assert Gstr1.coerce_correction("line_items[0].cgst_amount", "9") == 9.0
      assert Gstr1.coerce_correction("invoice_number", "1234") == "1234"
      assert Gstr1.coerce_correction("line_items[0].description", "9") == "9"
      assert Gstr1.coerce_correction("line_items[0].taxable_value", "9x") == "9x"
    end

    test "sums only extracted numeric line-item values without rounding" do
      invoice = %{
        "line_items" => [
          %{
            "taxable_value" => 100.25,
            "cgst_amount" => 9.02,
            "sgst_amount" => 9.02,
            "igst_amount" => nil
          },
          %{
            "taxable_value" => 50,
            "cgst_amount" => "4.5",
            "sgst_amount" => 0,
            "igst_amount" => 9.5
          }
        ]
      }

      assert Gstr1.extracted_totals(invoice) == %{taxable: 150.25, tax: 27.54}
    end
  end

  # A whole month end to end, on invoices small enough to read. The real corpus
  # cannot gate anything — its artifacts are gitignored, so a test keyed on them
  # reports "skipped" as if it were "passed" everywhere but one machine. Real
  # months are scored by `mix nila.eval score`, which keeps its numbers in run
  # records where they carry provenance.
  describe "derive/2 end to end against a filed return" do
    setup do
      invoices = [
        month_invoice("1", "33AABCP9487A1ZG", 1000, 18),
        month_invoice("2", "33AABCP9487A1ZG", 2000, 18),
        month_invoice("3", "29AAVCS8021P1ZB", 5000, 5)
      ]

      %{invoices: invoices, header: Gstr1.production_header("33AEWPH4158J1Z3", "2026-05")}
    end

    test "a return derived from invoices scores 100% against itself", %{
      invoices: invoices,
      header: header
    } do
      derived = Gstr1.derive(invoices, header)

      assert %{"score" => 100.0} = Gstr1Diff.diff(derived, derived)
    end

    test "groups invoices by counterparty and splits tax by place of supply", %{
      invoices: invoices,
      header: header
    } do
      derived = Gstr1.derive(invoices, header)

      assert [%{"ctin" => "29AAVCS8021P1ZB"}, %{"ctin" => "33AABCP9487A1ZG", "inv" => local}] =
               derived["b2b"]

      assert length(local) == 2

      # Seller and buyer are both 33, so the tax is CGST+SGST and IGST is zero.
      [%{"itms" => [%{"itm_det" => item}]} | _rest] = local
      assert item["camt"] == 90.0 and item["samt"] == 90.0 and item["iamt"] == 0

      # 29 against a 33 seller is interstate: IGST carries the whole tax.
      [%{"inv" => [%{"itms" => [%{"itm_det" => interstate}]}]} | _] = derived["b2b"]
      assert interstate["iamt"] == 250.0 and interstate["camt"] == 0
    end

    test "a missing invoice is visible as unmatched rows, not a quiet lower score", %{
      invoices: invoices,
      header: header
    } do
      filed = Gstr1.derive(invoices, header)
      short = Gstr1.derive(Enum.take(invoices, 2), header)

      rows = Gstr1Diff.rows(short, filed)
      missing = Enum.filter(rows, &(&1["key"] =~ "3" and is_nil(&1["derived"])))

      assert missing != []
      assert Gstr1Diff.score(rows)["score"] < 100.0
    end

    test "a wrong amount fails the row it is on and no others", %{
      invoices: invoices,
      header: header
    } do
      filed = Gstr1.derive(invoices, header)
      [first | rest] = invoices
      wrong = put_in(first, ["line_items", Access.at(0), "taxable_value"], 999)
      derived = Gstr1.derive([wrong | rest], header)

      mismatches = Gstr1Diff.diff(derived, filed)["mismatches"]
      {invoice_rows, hsn_rows} = Enum.split_with(mismatches, &(&1["scope"] != "hsn"))

      assert Enum.all?(invoice_rows, &(&1["key"] =~ "|1|")),
             "one bad amount must not smear across other invoices"

      # HSN is a turnover summary across the whole month, so a single wrong
      # amount legitimately moves its bucket too. That is why an HSN mismatch
      # cannot be attributed to an invoice by itself.
      assert hsn_rows != []
    end
  end

  describe "hsn_summary/1 and rate_summary/1 — one grouping for workings and portal" do
    setup do
      invoices = [
        month_invoice("1", "33AABCP9487A1ZG", 1000, 18),
        month_invoice("2", "33AABCP9487A1ZG", 2000, 18),
        month_invoice("3", "29AAVCS8021P1ZB", 5000, 5)
      ]

      %{invoices: invoices, header: Gstr1.production_header("33AEWPH4158J1Z3", "2026-05")}
    end

    test "hsn rows carry the invoices that built them, with each one's share", %{
      invoices: invoices
    } do
      summary = Gstr1.hsn_summary(invoices)

      eighteen = Enum.find(summary, &(&1["rt"] == 18))
      five = Enum.find(summary, &(&1["rt"] == 5))

      assert eighteen["txval"] == 3000.0
      assert Enum.map(eighteen["contribs"], & &1["inum"]) == ["1", "2"]
      assert five["txval"] == 5000.0
      assert five["contribs"] == [%{"inum" => "3", "txval" => 5000.0, "tax" => 250.0}]
    end

    test "official HSN descriptions stay on the review summary, not portal JSON", %{
      invoices: invoices,
      header: header
    } do
      invoices =
        update_in(invoices, [Access.at(0), "line_items", Access.at(0)], fn line ->
          Map.put(line, "hsn_description", "Other professional services")
        end)

      summary = Enum.find(Gstr1.hsn_summary(invoices), & &1["description"])
      assert summary["description"] == "Other professional services"

      derived = Gstr1.derive(invoices, header)
      refute Enum.any?(derived["hsn"]["hsn_b2b"], &Map.has_key?(&1, "description"))
    end

    test "a bucket's contributors account for the bucket", %{invoices: invoices} do
      for row <- Gstr1.hsn_summary(invoices) do
        contribs = row["contribs"]

        assert_in_delta Enum.sum(Enum.map(contribs, & &1["txval"])), row["txval"], 0.01

        assert_in_delta Enum.sum(Enum.map(contribs, & &1["tax"])),
                        row["camt"] + row["samt"] + row["iamt"],
                        0.01
      end
    end

    test "derive/2 files exactly these rows minus the contributor key", %{
      invoices: invoices,
      header: header
    } do
      derived = Gstr1.derive(invoices, header)

      stripped =
        invoices |> Gstr1.hsn_summary() |> Enum.map(&Map.drop(&1, ["contribs", "description"]))

      assert derived["hsn"]["hsn_b2b"] == stripped
    end

    test "rate_summary sums the derived b2b buckets and names contributors", %{
      invoices: invoices,
      header: header
    } do
      derived = Gstr1.derive(invoices, header)

      assert [five, eighteen] = Gstr1.rate_summary(derived)

      assert %{"rate" => 5, "taxable" => 5000.0, "tax" => 250.0} = five
      assert five["contribs"] == [%{"inum" => "3", "txval" => 5000.0, "tax" => 250.0}]

      assert eighteen["rate"] == 18
      assert eighteen["taxable"] == 3000.0
      assert eighteen["tax"] == 540.0
      assert eighteen["contribs"] |> Enum.map(& &1["inum"]) |> Enum.sort() == ["1", "2"]
    end
  end

  defp month_invoice(number, buyer_gstin, taxable, rate) do
    tax = taxable * rate / 100
    local? = String.starts_with?(buyer_gstin, "33")
    half = Float.round(tax / 2, 2)

    line =
      if local? do
        %{
          "taxable_value" => taxable,
          "hsn_sac" => "998719",
          "cgst_rate" => rate / 2,
          "cgst_amount" => half,
          "sgst_rate" => rate / 2,
          "sgst_amount" => half
        }
      else
        %{
          "taxable_value" => taxable,
          "hsn_sac" => "998719",
          "igst_rate" => rate,
          "igst_amount" => tax
        }
      end

    Gstr1.normalize_invoice(%{
      "data" => %{
        "invoice_number" => number,
        "invoice_date" => "04.05.2026",
        "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"gstin" => buyer_gstin},
        "printed_total_taxable" => taxable,
        "printed_total_tax" => tax,
        "printed_grand_total" => taxable + tax,
        "line_items" => [line]
      }
    })
  end

  defp seq_invoice(number) do
    Gstr1.normalize_invoice(%{
      "data" => %{
        "invoice_number" => number,
        "invoice_date" => "04.05.2026",
        "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_rate" => 9,
            "sgst_amount" => 90
          }
        ]
      }
    })
  end

  describe "blocking_issues/1 — documents this return has no table for" do
    # Six filed GSTR-1s across both clients contain b2b, hsn and doc_issue and
    # nothing else; doc_issue declares only series type 1. None of these
    # documents has ever arrived. When one does, it must stop the return rather
    # than be derived as the only shape on offer — a regular outward supply.
    defp sales_invoice(overrides) do
      Map.merge(
        %{
          "invoice_number" => "112/2025-26",
          "buyer_gstin" => "06AABCE4949G1ZN",
          "line_items" => [],
          "document" => %{}
        },
        overrides
      )
    end

    test "a credit note blocks, because filing it as a sale moves the liability twice" do
      invoice = sales_invoice(%{"document" => %{"credit_note" => true}})

      assert [issue] = Gstr1.blocking_issues([invoice])
      assert issue["code"] == "credit_note_unsupported"
      assert issue["level"] == "blocking"
      assert issue["invoice"] == "112/2025-26"
    end

    test "an export, an outward reverse charge and a missing buyer GSTIN each block" do
      export = sales_invoice(%{"id" => "source-a", "document" => %{"export" => true}})

      rcm =
        sales_invoice(%{
          "id" => "source-b",
          "invoice_number" => "113/2025-26",
          "document" => %{"reverse_charge" => true}
        })

      b2c =
        sales_invoice(%{
          "id" => "source-c",
          "invoice_number" => "114/2025-26",
          "buyer_gstin" => nil
        })

      codes =
        [export, rcm, b2c] |> Gstr1.blocking_issues() |> Enum.map(& &1["code"]) |> Enum.sort()

      assert codes == [
               "b2c_supply_unsupported",
               "export_supply_unsupported",
               "outward_reverse_charge_unsupported"
             ]
    end

    test "an ordinary uniquely numbered B2B invoice blocks nothing" do
      assert Gstr1.blocking_issues([sales_invoice(%{"id" => "source-a"})]) == []
    end

    test "duplicate invoice numbers block with an explicit source-group target" do
      invoices = [
        sales_invoice(%{"id" => "source-b"}),
        sales_invoice(%{"id" => "source-a"}),
        sales_invoice(%{"id" => "source-c", "invoice_number" => "113/2025-26"})
      ]

      assert [issue] = Gstr1.duplicate_number_issues(invoices)
      assert issue["invoice"] == "112/2025-26"
      assert issue["source_ids"] == ["source-a", "source-b"]
      assert issue["level"] == "blocking"

      assert issue["target"] ==
               "duplicate_invoice_number|112/2025-26|source-a,source-b"
    end

    test "a blocking issue cannot be cleared by confirming it" do
      # Every other issue is a question about the numbers, and a reviewer
      # confirming it is a real answer. This one says the return has no section
      # for the document, which confirmation does not change.
      confirmed = %{
        "level" => "blocking",
        "status" => "resolved",
        "code" => "credit_note_unsupported"
      }

      refute Nila.Gst.Sales.Workings.reviewable?([confirmed])

      assert Nila.Gst.Sales.Workings.reviewable?([
               %{"level" => "required", "status" => "resolved", "code" => "grand_total_mismatch"}
             ])
    end
  end
end
