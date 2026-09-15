defmodule Nila.Gst.Sales.Invoice.ValidationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation

  test "retained printed IGST drives both comparison values and mismatch checks" do
    for {printed, passed?} <- [{18, true}, {20, false}] do
      invoice =
        invoice(%{
          "printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => printed}]
        })

      assert Nila.Gst.Sales.Review.Values.printed(invoice).tax == printed

      check =
        Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "printed_tax_mismatch"))

      assert check["passed"] == passed?
      assert check["operands"]["printed"] == printed

      assert Enum.any?(
               InvoiceValidation.issues([invoice]),
               &(&1["code"] == "printed_tax_mismatch")
             ) == not passed?

      assert Nila.Gst.InvoiceFacts.to_sales_map(Nila.Gst.InvoiceFacts.sales!(invoice))[
               "printed_total_tax"
             ] == nil
    end
  end

  test "money tolerance is decided in exact paise" do
    invoice = invoice(%{}, %{"igst_amount" => 18.50})

    assert Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "line_arithmetic"))[
             "passed"
           ]

    invoice = invoice(%{}, %{"igst_amount" => 18.51})

    refute Enum.find(InvoiceValidation.checks(invoice), &(&1["code"] == "line_arithmetic"))[
             "passed"
           ]
  end

  test "missing taxable amounts do not turn an uncalculated tax total into a mismatch" do
    incomplete =
      invoice(
        %{"printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => 18}]},
        %{"taxable_value" => nil, "igst_rate" => nil, "igst_amount" => nil}
      )

    issues = InvoiceValidation.issues([incomplete])
    assert Enum.any?(issues, &(&1["code"] == "missing_taxable_value"))

    refute Enum.any?(
             InvoiceValidation.checks(incomplete),
             &(&1["code"] in ~w(printed_tax_mismatch grand_total_mismatch))
           )

    corrected = put_in(incomplete, ["line_items", Access.at(0), "igst_amount"], 20)

    assert Enum.any?(
             InvoiceValidation.issues([corrected]),
             &(&1["code"] == "printed_tax_mismatch")
           )
  end

  test "tax comparisons use tax inputs independently of taxable amounts" do
    invoice = invoice(%{"printed_total_tax" => 20}, %{"taxable_value" => nil})
    assert Enum.any?(InvoiceValidation.issues([invoice]), &(&1["code"] == "printed_tax_mismatch"))
    assert InvoiceValidation.comparison_totals(invoice) == %{taxable: nil, tax: 18.0, total: nil}
  end

  test "missing tax amounts defer comparisons but explicit zero remains comparable" do
    missing = invoice(%{"printed_total_tax" => 18}, %{"igst_amount" => nil})

    refute Enum.any?(
             InvoiceValidation.checks(missing),
             &(&1["code"] in ~w(line_arithmetic printed_tax_mismatch grand_total_mismatch))
           )

    assert InvoiceValidation.comparison_totals(missing).tax == nil

    zero = put_in(missing, ["line_items", Access.at(0), "igst_amount"], 0)
    assert Enum.any?(InvoiceValidation.issues([zero]), &(&1["code"] == "printed_tax_mismatch"))
    assert InvoiceValidation.comparison_totals(zero).tax == 0
  end

  test "missing tax amount is raised only when a taxable line needs tax evidence" do
    missing_igst = invoice(%{}, %{"igst_amount" => nil})

    assert [issue] =
             Enum.filter(
               InvoiceValidation.issues([missing_igst]),
               &(&1["code"] == "missing_tax_amount")
             )

    assert issue["lines"] == [1]
    assert issue["fields"] == ["line_items[0].igst_amount"]
    assert issue["level"] == "blocking"

    no_tax_facts =
      invoice(%{}, %{
        "igst_rate" => nil,
        "igst_amount" => nil,
        "cgst_rate" => nil,
        "cgst_amount" => nil,
        "sgst_rate" => nil,
        "sgst_amount" => nil
      })

    assert Enum.any?(
             InvoiceValidation.issues([no_tax_facts]),
             &(&1["code"] == "missing_tax_amount")
           )

    stated_zero = invoice(%{}, %{"igst_rate" => 18, "igst_amount" => 0})

    refute Enum.any?(
             InvoiceValidation.issues([stated_zero]),
             &(&1["code"] == "missing_tax_amount")
           )

    missing_split =
      invoice(%{}, %{
        "igst_rate" => nil,
        "igst_amount" => nil,
        "cgst_rate" => 9,
        "cgst_amount" => nil,
        "sgst_rate" => 9,
        "sgst_amount" => nil
      })

    assert Enum.any?(
             InvoiceValidation.issues([missing_split]),
             &(&1["code"] == "missing_tax_amount")
           )

    explicit_zero =
      invoice(%{}, %{
        "igst_rate" => 0,
        "igst_amount" => nil,
        "cgst_rate" => nil,
        "sgst_rate" => nil
      })

    refute Enum.any?(
             InvoiceValidation.issues([explicit_zero]),
             &(&1["code"] == "missing_tax_amount")
           )

    for overrides <- [
          %{"supply_type" => "exempt"},
          %{"supply_type" => "export", "tax_payment" => "without_payment"},
          %{"reverse_charge" => true}
        ] do
      exempt_or_excluded =
        Map.merge(invoice(%{}, %{"igst_rate" => 18, "igst_amount" => nil}), overrides)

      refute Enum.any?(
               InvoiceValidation.issues([exempt_or_excluded]),
               &(&1["code"] == "missing_tax_amount")
             )
    end
  end

  test "a partial split tax amount does not become a complete tax total" do
    invoice =
      invoice(%{}, %{
        "igst_amount" => nil,
        "igst_rate" => nil,
        "cgst_rate" => 9,
        "cgst_amount" => 9,
        "sgst_rate" => 9,
        "sgst_amount" => nil
      })

    assert InvoiceValidation.comparison_totals(invoice).tax == nil
  end

  test "bucket rounding uses canonical Decimal rates and paise" do
    lines =
      for index <- 1..3 do
        %{
          "description" => "Small item #{index}",
          "taxable_value" => 0.03,
          "cgst_rate" => if(index == 1, do: "9", else: 9.0),
          "cgst_amount" => if(index < 3, do: 0.01, else: 0),
          "sgst_rate" => if(index == 1, do: Decimal.new("9.00"), else: 9),
          "sgst_amount" => if(index < 3, do: 0.01, else: 0)
        }
      end

    issues =
      invoice(%{"line_items" => lines})
      |> then(&InvoiceValidation.issues([&1]))
      |> Enum.filter(&(&1["code"] == "rounding_variance"))

    assert length(issues) == 2
    assert Enum.all?(issues, &String.contains?(&1["message"], "× 18%"))
  end

  test "bill-to and ship-to disagreement does not invent a place-of-supply issue" do
    invoice =
      Normalizer.normalize(%{
        "data" => %{
          "invoice_number" => "PHILIPS-1",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
          "ship_to" => %{"state" => "Telangana", "state_code" => "36"},
          "line_items" => [
            %{
              "description" => "Equipment",
              "printed_taxable_value" => 100,
              "cgst_rate" => 9,
              "cgst_amount" => 9,
              "sgst_rate" => 9,
              "sgst_amount" => 9
            }
          ]
        }
      })

    issues = InvoiceValidation.issues([invoice])

    refute Enum.any?(
             issues,
             &(&1["code"] in ~w(place_of_supply_uncertain tax_treatment_uncertain))
           )

    derived = Gstr1.derive([invoice], %{"gstin" => "33AEWPH4158J1Z3", "fp" => "072026"})

    assert [%{"inv" => [%{"pos" => "33", "itms" => [%{"itm_det" => item}]}]}] =
             derived["b2b"]

    assert item["camt"] == 9
    assert item["samt"] == 9
    assert item["iamt"] == 0
  end

  test "missing evidence and inapplicable rules do not become successful outcomes" do
    outcomes = Nila.Gst.Sales.Invoice.Readiness.outcomes(invoice(%{})) |> Map.new(&{&1.id, &1})
    assert outcomes["seller_gstin"].status == :passed
    assert outcomes["seller_identity"].status == :not_checked
    assert outcomes["source_evidence"].status == :not_checked
    assert outcomes["b2c_units"].status == :not_applicable
    assert outcomes["duplicate_number"].status == :not_checked
    assert outcomes["hsn_directory"].status == :failed

    unannotated = invoice(%{}, %{"hsn_sac" => "998719"})

    assert Enum.find(
             Nila.Gst.Sales.Invoice.Readiness.outcomes(unannotated),
             &(&1.id == "hsn_directory")
           ).status == :not_checked
  end

  test "invalid seller state prevents a tax-head comparison" do
    outcomes =
      InvoiceValidation.outcomes(invoice(%{"seller_gstin" => "BAD", "place_of_supply" => nil}))
      |> Map.new(&{&1.id, &1})

    assert outcomes["seller_gstin"].status == :failed
    assert outcomes["tax_place"].status == :not_checked
    assert [%{"code" => "invalid_gstin"}] = outcomes["seller_gstin"].issues
  end

  test "HSN directory success and batch duplicate checks require their actual inputs" do
    bill = invoice(%{}, %{"hsn_sac" => "998719", "hsn_validation" => %{"status" => "valid"}})
    other = bill |> Map.put("id", "source-2")

    outcomes =
      Nila.Gst.Sales.Invoice.Readiness.outcomes(bill, [bill, other]) |> Map.new(&{&1.id, &1})

    assert outcomes["hsn_directory"].status == :passed
    assert outcomes["duplicate_number"].status == :failed
    unique = Nila.Gst.Sales.Invoice.Readiness.outcomes(bill, [bill]) |> Map.new(&{&1.id, &1})
    assert unique["duplicate_number"].status == :passed
  end

  test "a corrected invoice number is compared with the current batch" do
    bill = invoice(%{})
    other = invoice(%{"id" => "source-2", "invoice_number" => "INV-2"})
    corrected = Map.put(bill, "invoice_number", "INV-2")

    outcome =
      Nila.Gst.Sales.Invoice.Readiness.outcomes(corrected, [bill, other])
      |> Enum.find(&(&1.id == "duplicate_number"))

    assert outcome.status == :failed
  end

  test "tax-head outcomes report explicit and inferred comparisons with their actual basis" do
    explicit = InvoiceValidation.outcomes(invoice(%{})) |> Enum.find(&(&1.id == "tax_place"))
    assert explicit.status == :passed
    assert explicit.label == "Tax heads agree with place of supply"

    inferred_bill = invoice(%{"place_of_supply" => nil})
    inferred = InvoiceValidation.outcomes(inferred_bill) |> Enum.find(&(&1.id == "tax_place"))
    assert inferred.status == :passed
    assert inferred.label == "Tax heads agree with the buyer's state"
    assert inferred.detail == "Place of supply inferred from buyer GSTIN."

    conflicting =
      invoice(%{"place_of_supply" => nil}, %{
        "igst_amount" => nil,
        "igst_rate" => nil,
        "cgst_amount" => 9,
        "sgst_amount" => 9
      })

    failed = InvoiceValidation.outcomes(conflicting) |> Enum.find(&(&1.id == "tax_place"))
    assert failed.status == :failed
    assert [%{"code" => "tax_treatment_uncertain"}] = failed.issues

    missing =
      InvoiceValidation.outcomes(invoice(%{"place_of_supply" => nil, "buyer_gstin" => nil}))
      |> Enum.find(&(&1.id == "tax_place"))

    assert missing.status == :not_checked
  end

  test "unknown place of supply cannot receive a tax-head consistency pass" do
    outcome =
      InvoiceValidation.outcomes(invoice(%{"place_of_supply" => "XX"}))
      |> Enum.find(&(&1.id == "tax_place"))

    assert outcome.status == :not_checked
  end

  test "a missing split tax head cannot also pass tax amount completeness" do
    outcomes =
      InvoiceValidation.outcomes(
        invoice(%{}, %{
          "igst_amount" => nil,
          "igst_rate" => nil,
          "cgst_amount" => 9,
          "cgst_rate" => 9
        })
      )
      |> Map.new(&{&1.id, &1})

    assert outcomes["split_heads"].status == :failed
    assert outcomes["tax_amounts"].status == :not_checked
  end

  test "heading checks use item names when description is absent" do
    bill = invoice(%{}, %{"description" => nil, "item_name" => "COURIER CHARGES"})
    outcome = InvoiceValidation.outcomes(bill) |> Enum.find(&(&1.id == "line_structure"))
    assert outcome.status == :passed

    subtotal = invoice(%{}, %{"description" => nil, "item_name" => "Total"})

    assert Enum.any?(
             InvoiceValidation.issues([subtotal]),
             &(&1["code"] == "furniture_row_with_values")
           )
  end

  test "missing check reasons identify the missing fact without denying visible data" do
    bill = invoice(%{"place_of_supply" => nil}, %{"description" => nil, "item_name" => nil})
    outcomes = InvoiceValidation.outcomes(bill) |> Map.new(&{&1.id, &1})
    assert outcomes["tax_place"].status == :passed
    assert outcomes["tax_place"].detail =~ "inferred from buyer GSTIN"
    assert outcomes["line_structure"].reason =~ "missing on lines 1"
  end

  defp invoice(overrides, line_overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "source-1",
        "document_type" => "invoice",
        "document_status" => "active",
        "supply_type" => "taxable",
        "recipient_registration" => "registered",
        "place_of_supply" => "29",
        "invoice_number" => "INV-1",
        "invoice_date" => ~D[2026-07-15],
        "seller_gstin" => "33AEWPH4158J1Z3",
        "buyer_gstin" => "29AAVCS8021P1ZB",
        "line_items" => [
          Map.merge(
            %{
              "description" => "Support",
              "taxable_value" => 100,
              "igst_rate" => 18,
              "igst_amount" => 18
            },
            line_overrides
          )
        ]
      },
      overrides
    )
  end
end
