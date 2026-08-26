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

    # This module carried its own copy of the checksum, gated only on
    # `^\d{2}[A-Z0-9]{13}$`. A string with the wrong PAN shape and a
    # coincidentally correct check digit was valid to the filing engine and
    # invalid to purchase reconciliation and to the client form that captured
    # it.
    test "agrees with Nila.Gstin on structure, not just the check digit" do
      refute Gstr1.valid_gstin?("330ABCP9487A1ZG")
      assert Nila.Gstin.valid?("330ABCP9487A1ZG") == Gstr1.valid_gstin?("330ABCP9487A1ZG")
    end

    test "tolerates the case a scan gives us" do
      # The printed GSTIN is whatever the OCR read; `Nila.Gstin` itself stays
      # strict for the form fields that store a canonical value.
      assert Gstr1.valid_gstin?("33aewph4158j1z3")
      refute Nila.Gstin.valid?("33aewph4158j1z3")
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

    test "derives taxable value deterministically from a printed tax-inclusive line" do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "document_type" => "invoice",
            "document_status" => "active",
            "supply_type" => "taxable",
            "recipient_registration" => "unregistered",
            "place_of_supply" => "29",
            "invoice_number" => "INV-000006",
            "invoice_date" => "15.07.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"name" => "Consumer", "gstin" => nil},
            "line_items" => [
              %{
                "description" => "Tax-inclusive fixture",
                "hsn_sac" => "8471",
                "quantity" => 1,
                "uom" => "Nos",
                "printed_unit_price" => 110_000,
                "printed_line_amount" => 110_000,
                "printed_taxable_value" => nil,
                "line_amount_tax_inclusion" => "inclusive",
                "igst_rate" => 18,
                "igst_amount" => 16_779.66
              }
            ],
            "printed_total_taxable" => nil,
            "printed_total_tax" => 16_779.66,
            "printed_grand_total" => 110_000
          }
        })

      assert [line] = invoice["line_items"]
      assert line["taxable_value"] == 93_220.34
      assert line["taxable_value_basis"] == "derived_from_inclusive_line_amount"
      assert line["printed_line_amount"] == 110_000
      assert line["printed_taxable_value"] == nil
      assert line["line_amount_tax_inclusion"] == "inclusive"
      assert Gstr1.validation_issues([invoice]) == []
      assert Gstr1.filing_table(invoice) == "b2cl"

      derived = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})
      assert get_in(derived, ["b2cl", Access.at(0), "inv", Access.at(0), "val"]) == 110_000.0
    end

    test "ignores audited source failures for candidates absent from canonical data" do
      invoice =
        Gstr1.normalize_invoice(%{
          "verification" => %{
            "status" => "flagged",
            "failed_checks" => [
              %{
                "kind" => "source_presence",
                "field" => "printed_cgst",
                "detail" => "%{value: 90}"
              },
              %{
                "kind" => "grounding",
                "field" => "line_items[0].hsn_sac",
                "detail" => "not printed"
              }
            ]
          },
          "data" => %{
            "document_type" => "invoice",
            "document_status" => "active",
            "supply_type" => "taxable",
            "recipient_registration" => "unregistered",
            "place_of_supply" => "33",
            "invoice_number" => "GROUND-1",
            "invoice_date" => "15.07.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "line_items" => [
              %{
                "item_name" => "Fixture",
                "hsn_sac" => "8471",
                "quantity" => 1,
                "uom" => "Nos",
                "taxable_value" => 1_000,
                "cgst_rate" => 9,
                "cgst_amount" => 90,
                "sgst_rate" => 9,
                "sgst_amount" => 90
              }
            ],
            "printed_total_tax" => 180,
            "printed_grand_total" => 1_180
          }
        })

      assert get_in(invoice, ["verification", "status"]) == "flagged"

      assert [issue] =
               Enum.filter(
                 Gstr1.validation_issues([invoice]),
                 &(&1["code"] == "ungrounded_extracted_value")
               )

      assert issue["fields"] == ["line_items[0].hsn_sac"]
      refute "printed_cgst" in issue["fields"]
    end

    test "corrections canonicalize POS and recompute an inclusive line's taxable value" do
      invoice =
        b2c_invoice("INC-1", "2026-07-15", "29", 93_220.34, 16_779.66)
        |> Map.put("id", "source-inc")
        |> put_in(["line_items", Access.at(0), "printed_taxable_value"], nil)
        |> put_in(["line_items", Access.at(0), "printed_line_amount"], 110_000)
        |> put_in(["line_items", Access.at(0), "line_amount_tax_inclusion"], "inclusive")
        |> put_in(
          ["line_items", Access.at(0), "taxable_value_basis"],
          "derived_from_inclusive_line_amount"
        )

      flagged =
        MapSet.new([
          {"source-inc", "place_of_supply"},
          {"source-inc", "line_items[0].igst_rate"}
        ])

      corrections = [
        %{"source_id" => "source-inc", "field" => "place_of_supply", "value" => "Karnataka"},
        %{
          "source_id" => "source-inc",
          "field" => "line_items[0].igst_rate",
          "value" => Gstr1.coerce_correction("line_items[0].igst_rate", "12")
        }
      ]

      {[corrected], applied, [], _flags} =
        Gstr1.apply_corrections([invoice], corrections, flagged)

      assert length(applied) == 2
      assert corrected["place_of_supply"] == "29"
      assert get_in(corrected, ["line_items", Access.at(0), "taxable_value"]) == 98_214.29

      assert get_in(corrected, ["line_items", Access.at(0), "taxable_value_basis"]) ==
               "derived_from_inclusive_line_amount"
    end

    test "a reviewed taxable correction survives a later rate correction" do
      invoice =
        b2c_invoice("INC-CORRECTED", "2026-07-15", "29", 93_220.34, 16_779.66)
        |> Map.put("id", "source-corrected")
        |> put_in(["line_items", Access.at(0), "printed_taxable_value"], nil)
        |> put_in(["line_items", Access.at(0), "printed_line_amount"], 110_000)
        |> put_in(["line_items", Access.at(0), "line_amount_tax_inclusion"], "inclusive")

      flagged =
        MapSet.new([
          {"source-corrected", "line_items[0].taxable_value"},
          {"source-corrected", "line_items[0].igst_rate"}
        ])

      corrections = [
        %{
          "source_id" => "source-corrected",
          "field" => "line_items[0].taxable_value",
          "value" => 95_000
        },
        %{
          "source_id" => "source-corrected",
          "field" => "line_items[0].igst_rate",
          "value" => 12
        }
      ]

      {[corrected], _applied, [], _flags} =
        Gstr1.apply_corrections([invoice], corrections, flagged)

      assert get_in(corrected, ["line_items", Access.at(0), "taxable_value"]) == 95_000
      assert get_in(corrected, ["line_items", Access.at(0), "taxable_value_basis"]) == "corrected"
      assert get_in(corrected, ["line_items", Access.at(0), "igst_rate"]) == 12
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

  describe "unregistered B2C invoices" do
    test "missing GSTIN remains unknown unless registration is positively classified" do
      invoice = b2c_invoice("B2C-UNKNOWN", "2026-07-15", "KA", 10_000, 1_800, nil)

      assert invoice["recipient_registration"] == "unknown"
      assert Gstr1.filing_table(invoice) == nil

      assert Enum.any?(
               Gstr1.validation_issues([invoice]),
               &(&1["code"] == "unknown_recipient_registration")
             )
    end

    test "derives the controlled Zoho B2CS/B2CL boundary and B2C HSN shape" do
      below = b2c_invoice("INV-000004", "2026-07-15", "29", 76_271.19, 13_728.81)
      boundary = b2c_invoice("INV-000005", "2026-07-15", "29", 84_745.76, 15_254.24)
      above = b2c_invoice("INV-000006", "2026-07-15", "29", 93_220.34, 16_779.66)
      intrastate = b2c_invoice("INV-000003", "2026-07-15", "33", 42_372.88, 7_627.12)

      derived =
        Gstr1.derive(
          [below, boundary, above, intrastate],
          %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"}
        )

      assert Gstr1.filing_table(below) == "b2cs"
      assert Gstr1.filing_table(boundary) == "b2cs"
      assert Gstr1.filing_table(above) == "b2cl"
      assert Gstr1.filing_table(intrastate) == "b2cs"

      assert Enum.find(derived["b2cs"], &(&1["pos"] == "29")) == %{
               "pos" => "29",
               "typ" => "OE",
               "txval" => 161_016.95,
               "iamt" => 28_983.05,
               "camt" => 0.0,
               "samt" => 0.0,
               "csamt" => 0.0,
               "rt" => 18,
               "sply_ty" => "INTER"
             }

      assert [%{"pos" => "29", "inv" => [large]}] = derived["b2cl"]
      assert large["inum"] == "INV-000006"
      assert large["idt"] == "15-07-2026"
      assert large["val"] == 110_000.0

      assert get_in(large, ["itms", Access.at(0), "itm_det"]) == %{
               "rt" => 18,
               "txval" => 93_220.34,
               "iamt" => 16_779.66,
               "csamt" => 0
             }

      assert [hsn] = get_in(derived, ["hsn", "hsn_b2c"])
      assert hsn["hsn_sc"] == "8471"
      assert hsn["uqc"] == "NOS"
      assert hsn["qty"] == 4.0
      assert hsn["txval"] == 296_610.17
      assert hsn["iamt"] == 45_762.71
      assert hsn["camt"] == 3_813.56
      assert hsn["samt"] == 3_813.56
      assert get_in(derived, ["hsn", "hsn_b2b"]) == []
    end

    test "uses item name for HSN description and requires a missing goods UOM correction" do
      invoice =
        b2c_invoice("INV-UOM", "2026-07-15", "29", 10_000, 1_800)
        |> put_in(["line_items", Access.at(0), "item_name"], "Fixture product")
        |> put_in(
          ["line_items", Access.at(0), "description"],
          "Fixture product supplementary narrative"
        )
        |> put_in(["line_items", Access.at(0), "uom"], nil)

      assert [issue] =
               invoice
               |> then(&Gstr1.validation_issues([&1]))
               |> Enum.filter(&(&1["code"] == "missing_uom"))

      assert issue["fields"] == ["line_items[0].item_name", "line_items[0].uom"]
      assert Nila.Gst.Issues.resolution_kind(issue) == :correction

      corrected = put_in(invoice, ["line_items", Access.at(0), "uom"], "Nos")
      derived = Gstr1.derive([corrected], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})
      assert [hsn] = get_in(derived, ["hsn", "hsn_b2c"])
      assert hsn["desc"] == "Fixture product"
      assert hsn["uqc"] == "NOS"
    end

    test "numbers B2C HSN rows in first source occurrence order" do
      invoices = [
        b2c_invoice("HSN-1", "2026-07-15", "33", 1_000, 180),
        b2c_invoice("HSN-2", "2026-07-15", "33", 2_000, 360)
        |> put_in(["line_items", Access.at(0), "hsn_sac"], "1001")
        |> put_in(["line_items", Access.at(0), "uom"], "Kgs"),
        b2c_invoice("HSN-3", "2026-07-15", "33", 3_000, 540)
        |> put_in(["line_items", Access.at(0), "hsn_sac"], "2106")
      ]

      derived = Gstr1.derive(invoices, %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})

      assert Enum.map(derived["hsn"]["hsn_b2c"], &{&1["num"], &1["hsn_sc"]}) == [
               {1, "8471"},
               {2, "1001"},
               {3, "2106"}
             ]
    end

    test "uses NA consistently when ordering B2C service SAC rows" do
      invoice =
        b2c_invoice("SAC-1", "2026-07-15", "33", 1_000, 180)
        |> put_in(["line_items", Access.at(0), "hsn_sac"], "998719")
        |> put_in(["line_items", Access.at(0), "uom"], nil)

      derived = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})

      assert [%{"hsn_sc" => "998719", "uqc" => "NA", "num" => 1}] =
               derived["hsn"]["hsn_b2c"]
    end

    test "uses the historical B2CL threshold effective on the invoice date" do
      at_old_boundary = b2c_invoice("OLD-1", "2024-07-31", "29", 211_864.41, 38_135.59)
      above_old_boundary = b2c_invoice("OLD-2", "2024-07-31", "29", 211_864.42, 38_135.59)

      assert Gstr1.filing_table(at_old_boundary) == "b2cs"
      assert Gstr1.filing_table(above_old_boundary) == "b2cl"
    end

    test "blocks unregistered notes instead of misfiling them in CDNR" do
      note =
        b2c_invoice("CN-B2C-1", "2026-07-15", "29", 10_000, 1_800)
        |> Map.put("document_type", "credit_note")

      assert Gstr1.filing_table(note) == nil
      assert Enum.any?(Gstr1.blocking_issues([note]), &(&1["code"] == "cdnur_unsupported"))
      assert Gstr1.derive([note], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})["cdnr"] == []
    end
  end

  describe "registered credit notes" do
    test "normalizes the source note number and derives the filed January CDNR row" do
      note = credit_note()

      assert note["document_type"] == "credit_note"
      assert Gstr1.document_number(note) == "03/2024-25"
      assert Gstr1.document_date(note) == ~D[2025-01-03]
      assert Gstr1.document_effect(note) == -1

      derived =
        Gstr1.derive([note], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "012025"})

      assert derived["b2b"] == []

      assert derived["cdnr"] == [
               %{
                 "ctin" => "33AABCP9487A1ZG",
                 "nt" => [
                   %{
                     "nt_num" => "03/2024-25",
                     "nt_dt" => "03-01-2025",
                     "ntty" => "C",
                     "val" => 876_887.5,
                     "pos" => "33",
                     "rchrg" => "N",
                     "inv_typ" => "R",
                     "itms" => [
                       %{
                         "num" => 1,
                         "itm_det" => %{
                           "rt" => 18,
                           "txval" => 743_125,
                           "camt" => 66_881.25,
                           "samt" => 66_881.25,
                           "iamt" => 0,
                           "csamt" => 0
                         }
                       }
                     ]
                   }
                 ]
               }
             ]

      assert get_in(derived, ["doc_issue", "doc_det"]) == [
               %{
                 "doc_num" => 5,
                 "docs" => [
                   %{
                     "num" => 1,
                     "from" => "03/2024-25",
                     "to" => "03/2024-25",
                     "totnum" => 1,
                     "cancel" => 0,
                     "net_issue" => 1
                   }
                 ]
               }
             ]

      assert [hsn] = get_in(derived, ["hsn", "hsn_b2b"])
      assert hsn["txval"] == -743_125
      assert hsn["camt"] == -66_881.25
      assert hsn["samt"] == -66_881.25
      assert Gstr1.blocking_issues([note]) == []
    end

    test "derives the verified Zoho debit-note shape with positive liability effect" do
      note = debit_note()

      assert note["document_type"] == "debit_note"
      assert Gstr1.document_number(note) == "CDN-000001"
      assert Gstr1.document_date(note) == ~D[2026-08-10]
      assert Gstr1.document_effect(note) == 1

      derived =
        Gstr1.derive([note], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "082026"})

      assert derived["b2b"] == []

      assert derived["cdnr"] == [
               %{
                 "ctin" => "29AAVCS8021P1ZB",
                 "nt" => [
                   %{
                     "nt_num" => "CDN-000001",
                     "nt_dt" => "10-08-2026",
                     "ntty" => "D",
                     "val" => 11_800,
                     "pos" => "29",
                     "rchrg" => "N",
                     "inv_typ" => "R",
                     "itms" => [
                       %{
                         "num" => 1,
                         "itm_det" => %{
                           "rt" => 18,
                           "txval" => 10_000,
                           "camt" => 0,
                           "samt" => 0,
                           "iamt" => 1_800,
                           "csamt" => 0
                         }
                       }
                     ]
                   }
                 ]
               }
             ]

      assert get_in(derived, ["doc_issue", "doc_det"]) == [
               %{
                 "doc_num" => 4,
                 "docs" => [
                   %{
                     "num" => 1,
                     "from" => "CDN-000001",
                     "to" => "CDN-000001",
                     "totnum" => 1,
                     "cancel" => 0,
                     "net_issue" => 1
                   }
                 ]
               }
             ]

      assert [hsn] = get_in(derived, ["hsn", "hsn_b2b"])
      assert hsn["txval"] == 10_000
      assert hsn["iamt"] == 1_800
      assert Gstr1.blocking_issues([note]) == []
    end

    test "classification disagreement blocks instead of flipping liability silently" do
      invoice =
        Gstr1.normalize_invoice(%{
          "document" => %{
            "credit_note" => true,
            "debit_note" => false,
            "extracted_type" => "invoice"
          },
          "data" => %{
            "document_type" => "invoice",
            "invoice_number" => "03/2024-25",
            "invoice_date" => "03.01.2025",
            "line_items" => []
          }
        })

      assert [issue] =
               Gstr1.validation_issues([invoice])
               |> Enum.filter(&(&1["code"] == "document_type_conflict"))

      assert issue["level"] == "blocking"
      assert issue["fields"] == ["document_type"]
    end

    test "a credit note and invoice with the same number are not duplicate documents" do
      invoice = %{dated("03.01.2025") | "invoice_number" => "03/2024-25"}
      assert Gstr1.duplicate_number_issues([invoice, credit_note()]) == []
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

  defp credit_note do
    Gstr1.normalize_invoice(%{
      "page" => 1,
      "document" => %{"credit_note" => true, "debit_note" => false},
      "data" => %{
        "invoice_number" => "Credit Note:03/2024-25",
        "invoice_date" => "03.01.2025",
        "seller" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "Philips India Ltd", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          %{
            "description" => "AMC for Turnkey work for 29 Customers",
            "hsn_sac" => "998719",
            "quantity" => 29,
            "unit_price" => 25_625,
            "taxable_value" => 743_125,
            "cgst_rate" => 9,
            "cgst_amount" => 66_881.25,
            "sgst_rate" => 9,
            "sgst_amount" => 66_881.25
          }
        ],
        "printed_total_taxable" => 743_125,
        "printed_total_tax" => 133_762.5,
        "printed_grand_total" => 876_887.5
      }
    })
  end

  defp debit_note do
    Gstr1.normalize_invoice(%{
      "page" => 1,
      "document" => %{"credit_note" => false, "debit_note" => true},
      "data" => %{
        "document_type" => "debit_note",
        "invoice_number" => "CDN-000001",
        "invoice_date" => "2026-08-10",
        "seller" => %{"name" => "Seller", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "Buyer", "gstin" => "29AAVCS8021P1ZB"},
        "line_items" => [
          %{
            "description" => "Additional charge test",
            "hsn_sac" => "998719",
            "unit_price" => 10_000,
            "taxable_value" => 10_000,
            "igst_rate" => 18,
            "igst_amount" => 1_800
          }
        ],
        "printed_total_taxable" => 10_000,
        "printed_total_tax" => 1_800,
        "printed_grand_total" => 11_800
      }
    })
  end

  defp b2c_invoice(number, date, place_of_supply, taxable, tax, registration \\ "unregistered") do
    tax_fields =
      if place_of_supply == "33" do
        %{
          "cgst_rate" => 9,
          "cgst_amount" => tax / 2,
          "sgst_rate" => 9,
          "sgst_amount" => tax / 2
        }
      else
        %{"igst_rate" => 18, "igst_amount" => tax}
      end

    Gstr1.normalize_invoice(%{
      "data" => %{
        "document_type" => "invoice",
        "document_status" => "active",
        "supply_type" => "taxable",
        "recipient_registration" => registration,
        "place_of_supply" => place_of_supply,
        "invoice_number" => number,
        "invoice_date" => date,
        "seller" => %{"name" => "Seller", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "Unregistered buyer", "gstin" => nil},
        "line_items" => [
          Map.merge(
            %{
              "description" => "Synthetic fixture goods",
              "hsn_sac" => "8471",
              "quantity" => 1,
              "uom" => "Nos",
              "unit_price" => taxable,
              "taxable_value" => taxable
            },
            tax_fields
          )
        ],
        "printed_total_taxable" => taxable,
        "printed_total_tax" => tax,
        "printed_grand_total" => taxable + tax
      }
    })
  end

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

  describe "validation_issues/1 — an invoice that contradicts itself" do
    # Seller KA, buyer TN. One line IGST ₹900, another CGST ₹450 + SGST ₹450.
    defp mixed_head_invoice(seller \\ "29AAVCS8021P1ZB", buyer \\ "33AEWPH4158J1Z3") do
      Gstr1.normalize_invoice(%{
        "data" => %{
          "invoice_number" => "MIX-1",
          "invoice_date" => "04.05.2026",
          "seller" => %{"gstin" => seller},
          "buyer" => %{"gstin" => buyer},
          "line_items" => [
            %{"taxable_value" => 5000, "igst_rate" => 18, "igst_amount" => 900},
            %{
              "taxable_value" => 5000,
              "cgst_rate" => 9,
              "cgst_amount" => 450,
              "sgst_rate" => 9,
              "sgst_amount" => 450
            }
          ],
          "printed_total_taxable" => 10_000.0,
          "printed_total_tax" => 1800.0,
          "printed_grand_total" => 11_800.0
        }
      })
    end

    test "both heads on one bill is raised, and it gates" do
      invoice = mixed_head_invoice()
      issues = Gstr1.validation_issues([invoice])

      assert issue = Enum.find(issues, &(&1["code"] == "mixed_tax_heads"))
      assert issue["fields"] == ["line_items"]
      assert issue["message"] =~ "one supply has one place of supply"
      assert issue["tax_heads"] == ["igst", "cgst", "sgst"]
      assert issue["igst"] == 900.0
      assert issue["split_tax"] == 900.0
      assert Nila.Gst.Issues.gating?(issue)
      assert Nila.Gst.Issues.resolution_kind(issue) == :decision
    end

    test "tax-head evidence lists only heads with positive extracted amounts" do
      invoice =
        mixed_head_invoice()
        |> put_in(["line_items", Access.at(1), "sgst_amount"], 0)

      issue =
        invoice
        |> then(&Gstr1.validation_issues([&1]))
        |> Enum.find(&(&1["code"] == "mixed_tax_heads"))

      assert issue["tax_heads"] == ["igst", "cgst"]
    end

    # This is why the check has to exist: every other signal reads clean while
    # ₹900 of tax silently changes head in the return.
    test "nothing else catches it — the totals agree and the filing looks fine" do
      invoice = mixed_head_invoice()

      assert Enum.all?(Gstr1.invoice_checks(invoice), & &1["passed"])

      derived = Gstr1.derive([invoice], Gstr1.production_header("29AAVCS8021P1ZB", "2026-05"))
      values = Nila.Gst.Sales.Values.for_invoice(invoice, derived)

      assert values.extracted_lines.tax == values.filed.tax
      assert values.filed.igst == 1800.0
      assert values.filed.cgst == 0.0
      refute values.head_reassignment
    end

    test "it does not double up with the GSTIN-versus-heads check" do
      # `tax_split_mismatch` says the GSTIN pair contradicts the heads. Here the
      # invoice contradicts itself, which is the stronger claim and does not
      # depend on the GSTINs being right — asking both would be one malformed
      # bill answered twice.
      codes = Gstr1.validation_issues([mixed_head_invoice()]) |> Enum.map(& &1["code"])

      assert "mixed_tax_heads" in codes
      refute "tax_split_mismatch" in codes
    end

    test "one head only is left to the GSTIN check" do
      # Interstate parties, CGST/SGST only: that is `tax_split_mismatch`'s job
      # and this check must stay quiet.
      intra_on_interstate =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "SPLIT-1",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "29AAVCS8021P1ZB"},
            "buyer" => %{"gstin" => "33AEWPH4158J1Z3"},
            "line_items" => [
              %{
                "taxable_value" => 10_000,
                "cgst_rate" => 9,
                "cgst_amount" => 900,
                "sgst_rate" => 9,
                "sgst_amount" => 900
              }
            ]
          }
        })

      issues = Gstr1.validation_issues([intra_on_interstate])
      codes = Enum.map(issues, & &1["code"])

      refute "mixed_tax_heads" in codes
      assert "tax_split_mismatch" in codes

      mismatch = Enum.find(issues, &(&1["code"] == "tax_split_mismatch"))
      assert mismatch["seller_state"] == "29"
      assert mismatch["place_of_supply"] == "33"
      assert mismatch["place_field"] == "buyer_gstin"
      assert mismatch["tax_heads"] == ["cgst", "sgst"]
    end

    test "tax-split evidence excludes a zero-valued split head" do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "SPLIT-2",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "29AAVCS8021P1ZB"},
            "buyer" => %{"gstin" => "33AEWPH4158J1Z3"},
            "line_items" => [
              %{
                "taxable_value" => 10_000,
                "cgst_rate" => 9,
                "cgst_amount" => 900,
                "sgst_rate" => 9,
                "sgst_amount" => 0
              }
            ]
          }
        })

      issue =
        invoice
        |> then(&Gstr1.validation_issues([&1]))
        |> Enum.find(&(&1["code"] == "tax_split_mismatch"))

      assert issue["tax_heads"] == ["cgst"]
    end

    test "an ordinary single-head bill raises neither" do
      ordinary =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "OK-1",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => [
              %{
                "taxable_value" => 10_000,
                "cgst_rate" => 9,
                "cgst_amount" => 900,
                "sgst_rate" => 9,
                "sgst_amount" => 900
              }
            ]
          }
        })

      codes = Gstr1.validation_issues([ordinary]) |> Enum.map(& &1["code"])

      refute "mixed_tax_heads" in codes
      refute "tax_split_mismatch" in codes
    end
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

      issue =
        invoice
        |> then(&Gstr1.validation_issues([&1]))
        |> Enum.find(&(&1["code"] == "grand_total_mismatch"))

      assert issue["operands"] == %{"printed" => 275_000.0, "derived" => 76_171.36}
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

    # Three failing lines are three ✗ marks and one question: they post the same
    # resolution target, so three cards meant answering one cleared all three.
    test "lines failing the same check are one issue carrying all of them" do
      invoice = %{
        "id" => "inv_01",
        "invoice_number" => "20/2026-27",
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 50,
            "sgst_rate" => 9,
            "sgst_amount" => 50
          },
          %{
            "taxable_value" => 500,
            "cgst_rate" => 9,
            "cgst_amount" => 45,
            "sgst_rate" => 9,
            "sgst_amount" => 45
          },
          %{
            "taxable_value" => 200,
            "cgst_rate" => 9,
            "cgst_amount" => 10,
            "sgst_rate" => 9,
            "sgst_amount" => 10
          }
        ]
      }

      failed = invoice |> Gstr1.invoice_checks() |> Enum.reject(& &1["passed"])
      assert length(failed) == 2

      assert [issue] =
               [invoice]
               |> Gstr1.validation_issues()
               |> Enum.filter(&(&1["code"] == "line_arithmetic"))

      assert issue["lines"] == [1, 3]
      assert issue["message"] =~ "line 1 tax 100"
      assert issue["message"] =~ "line 3 tax 20"
      assert "line_items[0].taxable_value" in issue["fields"]
      assert "line_items[2].taxable_value" in issue["fields"]
    end

    test "a bill total out by what its components are out by folds into theirs" do
      invoice = %{
        "id" => "inv_01",
        "invoice_number" => "20/2026-27",
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_rate" => 9,
            "sgst_amount" => 90
          }
        ],
        "printed_total_taxable" => 1100,
        "printed_total_tax" => 180,
        "printed_grand_total" => 1280
      }

      codes = [invoice] |> Gstr1.validation_issues() |> Enum.map(& &1["code"])
      assert "printed_taxable_mismatch" in codes
      refute "grand_total_mismatch" in codes

      issue =
        [invoice]
        |> Gstr1.validation_issues()
        |> Enum.find(&(&1["code"] == "printed_taxable_mismatch"))

      assert issue["message"] =~ "printed taxable total does not match line taxable sum"
      assert issue["message"] =~ "printed bill total"
      assert issue["message"] =~ "printed 1280.0, derived 1180.0"
      assert "printed_grand_total" in issue["fields"]
      assert issue["operands"] == %{"printed" => 1100, "derived" => 1000}
      assert issue["grand_total_operands"] == %{"printed" => 1280, "derived" => 1180}
    end

    test "a bill total wrong on its own stays its own issue" do
      invoice = %{
        "id" => "inv_01",
        "invoice_number" => "20/2026-27",
        "line_items" => [
          %{
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_rate" => 9,
            "sgst_amount" => 90
          }
        ],
        "printed_total_taxable" => 1100,
        "printed_total_tax" => 180,
        "printed_grand_total" => 9999
      }

      codes = [invoice] |> Gstr1.validation_issues() |> Enum.map(& &1["code"])
      assert "printed_taxable_mismatch" in codes
      assert "grand_total_mismatch" in codes
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

    test "multiple prefixed series report every gap without combining their ranges" do
      invoices = [
        seq_invoice("INV-001"),
        seq_invoice("INV-003"),
        seq_invoice("20/2026-27"),
        seq_invoice("22/2026-27")
      ]

      account = Gstr1.series_account(invoices)
      assert account.missing == ["21/2026-27", "INV-002"]

      [issue] = Enum.filter(Gstr1.validation_issues(invoices), &(&1["code"] == "sequence_gaps"))
      assert issue["message"] =~ "21/2026-27"
      assert issue["message"] =~ "INV-002"
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
      assert Gstr1.coerce_correction("printed_total_taxable", " ") == nil
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

    test "registered credit and debit notes are both supported" do
      credit =
        sales_invoice(%{
          "document_type" => "credit_note",
          "document" => %{"credit_note" => true}
        })

      debit =
        sales_invoice(%{
          "document_type" => "debit_note",
          "document" => %{"debit_note" => true}
        })

      assert Gstr1.blocking_issues([credit, debit]) == []
    end

    test "an export and an outward reverse charge block while taxable B2C is supported" do
      export = sales_invoice(%{"id" => "source-a", "document" => %{"export" => true}})

      rcm =
        sales_invoice(%{
          "id" => "source-b",
          "invoice_number" => "113/2025-26",
          "document" => %{"reverse_charge" => true}
        })

      codes =
        [export, rcm] |> Gstr1.blocking_issues() |> Enum.map(& &1["code"]) |> Enum.sort()

      assert codes == ["export_supply_unsupported", "outward_reverse_charge_unsupported"]
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

    test "the same number in a different case is one invoice issued twice" do
      # Grouping on the raw printed text let this pair through as two distinct
      # invoices, so a genuine duplicate did not block.
      invoices = [
        sales_invoice(%{"id" => "source-a", "invoice_number" => "inv/112"}),
        sales_invoice(%{"id" => "source-b", "invoice_number" => "INV/112"})
      ]

      assert [issue] = Gstr1.duplicate_number_issues(invoices)
      assert issue["source_ids"] == ["source-a", "source-b"]
      # The message still names the number as it was actually read.
      assert issue["invoice"] in ["inv/112", "INV/112"]
    end

    test "a blocking issue cannot be cleared by confirming it" do
      # Every other issue is a question about the numbers, and a reviewer
      # confirming it is a real answer. This one says the return has no section
      # for the document, which confirmation does not change.
      confirmed = %{
        "level" => "blocking",
        "status" => "resolved",
        "code" => "export_supply_unsupported"
      }

      refute Nila.Gst.Sales.Workings.reviewable?([confirmed])

      assert Nila.Gst.Sales.Workings.reviewable?([
               %{"level" => "required", "status" => "resolved", "code" => "grand_total_mismatch"}
             ])
    end
  end
end
