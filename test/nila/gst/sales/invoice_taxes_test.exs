defmodule Nila.Gst.Sales.InvoiceTaxesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.Invoice.Validation

  test "a sole item receives the printed footer taxes without inventing printed item components" do
    source = invoice([92_700], split_taxes(8_343))
    resolved = Invoice.resolve_line_amounts(source)
    [line] = resolved["line_items"]

    assert line["cgst_rate"] == 9
    assert line["sgst_rate"] == 9
    assert line["cgst_amount"] == 8_343
    assert line["sgst_amount"] == 8_343
    assert line["printed_tax_components"] == []
    assert resolved["printed_tax_totals"] == source["printed_tax_totals"]
    assert Invoice.extracted_totals(resolved) == %{taxable: 92_700.0, tax: 16_686.0}
    refute missing_tax?(resolved)
  end

  test "printed footer rates allocate ETS taxes and reconcile against each printed tax head" do
    source = invoice([49_500, 48_000], split_taxes(8_775, true))
    resolved = Invoice.resolve_line_amounts(source)
    [first, second] = resolved["line_items"]

    assert {first["cgst_amount"], first["sgst_amount"]} == {4_455, 4_455}
    assert {second["cgst_amount"], second["sgst_amount"]} == {4_320, 4_320}
    assert Invoice.extracted_totals(resolved) == %{taxable: 97_500.0, tax: 17_550.0}
    assert resolved["printed_tax_totals"] == source["printed_tax_totals"]
    assert Enum.all?(resolved["line_items"], &(&1["printed_tax_components"] == []))
    refute missing_tax?(resolved)
  end

  test "unknown rates on multiple items retain known invoice taxes and require review" do
    resolved = invoice([49_500, 48_000], split_taxes(8_775)) |> Invoice.resolve_line_amounts()

    assert Enum.all?(resolved["line_items"], &is_nil(&1["cgst_amount"]))
    assert Invoice.extracted_totals(resolved).tax == 17_550
    assert missing_tax?(resolved)
  end

  test "an average invoice rate is not evidence that every item has that rate" do
    resolved = invoice([100, 100], split_taxes(14)) |> Invoice.resolve_line_amounts()

    assert Enum.all?(resolved["line_items"], &is_nil(&1["cgst_rate"]))
    assert Enum.all?(resolved["line_items"], &is_nil(&1["sgst_amount"]))
    assert Invoice.extracted_totals(resolved).tax == 28
    assert missing_tax?(resolved)
  end

  test "existing wrong item tax is retained and raises a mismatch rather than being silently repaired" do
    source =
      invoice([100], split_taxes(9))
      |> update_in(["line_items", Access.at(0)], fn line ->
        Map.merge(line, %{
          "cgst_rate" => 9,
          "sgst_rate" => 9,
          "cgst_amount" => 18,
          "sgst_amount" => 18
        })
      end)

    resolved = Invoice.resolve_line_amounts(source)
    [line] = resolved["line_items"]
    assert line["cgst_amount"] == 18
    assert line["sgst_amount"] == 18
    assert Enum.any?(Validation.checks(resolved), &(&1["passed"] == false))
  end

  test "resolving the same invoice repeatedly does not change its calculated taxes" do
    once = invoice([49_500, 48_000], split_taxes(8_775, true)) |> Invoice.resolve_line_amounts()
    assert Invoice.resolve_line_amounts(once) == once
  end

  test "changing footer amounts replaces prior derived sole-item taxes" do
    first = invoice([100], split_taxes(9)) |> Invoice.resolve_line_amounts()

    changed =
      first |> Map.put("printed_tax_totals", split_taxes(6)) |> Invoice.resolve_line_amounts()

    [line] = changed["line_items"]
    assert line["cgst_amount"] == 6
    assert line["sgst_amount"] == 6
    assert line["cgst_rate"] == 6
  end

  test "an accountant's correction is not erased when old derived taxes are reset" do
    resolved =
      invoice([100], split_taxes(9))
      |> Invoice.resolve_line_amounts()
      |> Invoice.apply_correction("line_items[0].cgst_amount", 10)
      |> Invoice.resolve_line_amounts()

    [line] = resolved["line_items"]
    assert line["cgst_amount"] == 10
    assert missing_tax?(resolved)
  end

  test "changing a base clears stale allocations when they no longer match the footer" do
    first = invoice([49_500, 48_000], split_taxes(8_775, true)) |> Invoice.resolve_line_amounts()

    changed =
      first
      |> put_in(["line_items", Access.at(0), "printed_taxable_value"], 50_000)
      |> Invoice.resolve_line_amounts()

    assert Enum.all?(changed["line_items"], &is_nil(&1["cgst_amount"]))
    assert Invoice.extracted_totals(changed).tax == 17_550
    assert missing_tax?(changed)
  end

  test "combined item GST supplies a taxable base and footer split without changing printed components" do
    components = [%{"printed_label" => "GST", "printed_rate" => 18, "printed_amount" => 442.8}]

    source =
      invoice([nil], split_taxes(221.4))
      |> update_in(["line_items", Access.at(0)], fn line ->
        Map.merge(line, %{"printed_line_total" => 2_902.8, "printed_tax_components" => components})
      end)

    resolved = Invoice.resolve_line_amounts(source)
    [line] = resolved["line_items"]
    assert line["taxable_value"] == 2_460
    assert line["cgst_amount"] == 221.4
    assert line["sgst_amount"] == 221.4
    assert line["printed_tax_components"] == components
    assert Invoice.extracted_totals(resolved) == %{taxable: 2_460.0, tax: 442.8}
  end

  test "invoice-level discounts and charges prevent assigning their tax to an item" do
    for field <- ["printed_discount_amount", "printed_additional_charges"] do
      resolved =
        invoice([100], split_taxes(9))
        |> Map.put(field, 10)
        |> Invoice.resolve_line_amounts()

      assert Enum.all?(resolved["line_items"], &is_nil(&1["cgst_amount"]))
      assert Invoice.extracted_totals(resolved).tax == 18
      assert missing_tax?(resolved)
    end
  end

  defp missing_tax?(invoice),
    do: Enum.any?(Validation.issues([invoice]), &(&1["code"] == "missing_tax_amount"))

  defp split_taxes(amount, with_rates? \\ false) do
    for head <- ["CGST", "SGST"] do
      %{
        "printed_label" => if(with_rates?, do: head <> "9 (9%)", else: head),
        "printed_amount" => amount
      }
    end
  end

  defp invoice(bases, components) do
    %{
      "invoice_number" => "TEST-1",
      "invoice_date" => "2026-06-16",
      "document_type" => "invoice",
      "supply_type" => "taxable",
      "buyer_gstin" => "33AACCR5866L1ZZ",
      "seller_gstin" => "33AEHFS3648M1ZL",
      "printed_tax_totals" => components,
      "line_items" =>
        Enum.map(bases, fn base ->
          %{
            "description" => "Item",
            "hsn_sac" => "85412900",
            "printed_taxable_value" => base,
            "printed_tax_components" => []
          }
        end)
    }
  end
end
