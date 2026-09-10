defmodule Nila.Gst.Extraction.Sales.NormalizerTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Review.CorrectionPolicy
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Gstr1

  test "stored artifact envelopes and field aliases preserve the same invoice facts" do
    data = %{
      "inum" => " 12 / 2026-27 ",
      "idt" => "04-May-26",
      "seller" => %{"name" => "Seller", "gstin" => "33AEWPH4158J1Z3"},
      "buyer" => %{"name" => "Buyer", "gstin" => "33AABCP9487A1ZG"},
      "total_net_amount" => "1,000",
      "total_tax_amount" => "180",
      "total_gross_amount" => "1,180",
      "line_items" => [
        %{
          "hsn_sc" => 8471,
          "qty" => "1",
          "unit" => "NOS",
          "printed_taxable_value" => "1,000",
          "cgst" => %{"rate" => "9", "amount" => "90"},
          "sgst" => %{"rate" => "9", "amount" => "90"}
        }
      ]
    }

    expected = Normalizer.normalize(data)

    for envelope <- ["data", "extract_result", "result"] do
      assert Normalizer.normalize(%{envelope => data}) == expected
    end

    assert expected["invoice_number"] == "12/2026-27"
    assert expected["invoice_date"] == ~D[2026-05-04]
    assert expected["printed_grand_total"] == 1180
    assert expected["recipient_registration"] == "registered"

    assert [
             %{
               "hsn_sac" => "8471",
               "quantity" => 1,
               "uom" => "NOS",
               "taxable_value" => 1000,
               "cgst_rate" => 9,
               "cgst_amount" => 90
             }
           ] = expected["line_items"]
  end

  test "document markers, source evidence, and nested confidence survive normalization" do
    confidence = %{"invoice_number" => %{"confidence" => 0.4}}
    verification = %{"status" => "flagged", "failed_checks" => []}

    artifact = %{
      "page" => 2,
      "source_pages" => [2, 3],
      "source_attribution" => %{"basis" => "grouped"},
      "document" => %{"credit_note" => true},
      "verification" => verification,
      "extract_metadata" => %{"field_metadata" => %{"document_metadata" => confidence}},
      "data" => %{
        "invoice_number" => "Credit Note No: 12 / 26",
        "invoice_date" => "unreadable",
        "line_items" => []
      }
    }

    invoice = Normalizer.normalize(artifact)
    assert invoice["document_type"] == "credit_note"
    assert invoice["invoice_number"] == "12/26"
    assert invoice["invoice_date"] == "unreadable"
    assert invoice["source_pages"] == [2, 3]
    assert invoice["source_attribution"] == artifact["source_attribution"]
    assert invoice["verification"] == verification
    assert invoice["confidence"] == confidence

    assert MapSet.member?(
             CorrectionPolicy.flagged_fields([invoice], []),
             {"12/26", "invoice_number"}
           )

    explicit = %{"invoice_number" => 0.99}

    assert Normalizer.normalize(Map.put(artifact, "confidence", explicit))["confidence"] ==
             explicit
  end

  describe "normalize/1" do
    test "preserves sales party roles without treating ship-to as place of supply" do
      invoice =
        Normalizer.normalize(%{
          "data" => %{
            "document_type" => "invoice",
            "document_status" => "active",
            "supply_type" => "taxable",
            "recipient_registration" => "registered",
            "invoice_number" => "38/2026-27",
            "invoice_date" => "09.06.2026",
            "supplier" => %{
              "name" => "Breeze Tech",
              "gstin" => "33AEWPH4158J1Z3",
              "address" => "Chennai",
              "state_code" => "33"
            },
            "bill_to" => %{
              "name" => "Philips India Ltd",
              "gstin" => "33AABCP9487A1ZG",
              "address" => "Chennai",
              "state_code" => "33"
            },
            "ship_to" => %{
              "name" => "Osmania General Hospital",
              "gstin" => nil,
              "address" => "Hyderabad",
              "state_code" => "36"
            },
            "printed_place_of_supply" => nil,
            "line_items" => []
          }
        })

      assert invoice["seller_gstin"] == "33AEWPH4158J1Z3"
      assert invoice["buyer_gstin"] == "33AABCP9487A1ZG"
      assert invoice["bill_to"]["state_code"] == "33"
      assert invoice["ship_to"]["state_code"] == "36"
      assert invoice["place_of_supply"] == nil
    end

    test "drops degenerate lines and lifts nested seller/buyer" do
      raw = %{
        "page" => 1,
        "data" => %{
          "invoice_number" => " 20 / 2026-27 ",
          "invoice_date" => "04.05.2026",
          "seller" => %{"name" => "S", "gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"name" => "B", "gstin" => "33AABCP9487A1ZG"},
          "line_items" => [
            %{"printed_taxable_value" => 1000, "cgst_amount" => 90, "sgst_amount" => 90},
            %{"printed_taxable_value" => 0, "quantity" => 0}
          ]
        }
      }

      invoice = Normalizer.normalize(raw)
      assert invoice["invoice_number"] == "20/2026-27"
      assert invoice["seller_gstin"] == "33AEWPH4158J1Z3"
      assert length(invoice["line_items"]) == 1
    end

    test "derives taxable value deterministically from a printed tax-inclusive line" do
      invoice =
        Normalizer.normalize(%{
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
        Normalizer.normalize(%{
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
                "printed_taxable_value" => 1_000,
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
  end
end
