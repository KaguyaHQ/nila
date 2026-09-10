defmodule Nila.EvalTest do
  @moduledoc """
  Covers the scoring seam: adjudications changing what a month scores, and the
  `reviewed` leg going through the product's own correction path rather than a
  second copy of it.
  """
  use ExUnit.Case, async: true

  alias Nila.Eval
  alias Nila.Eval.Segmentation
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Workings

  describe "run_id/0" do
    test "sorts chronologically and names the code that produced it" do
      assert Eval.run_id() =~ ~r/^\d{4}-\d{2}-\d{2}T[\d-]+Z-[0-9a-f]+(-dirty)?$/
    end
  end

  describe "reviewed leg" do
    setup do
      invoice =
        Gstr1.normalize_invoice(%{
          "data" => %{
            "invoice_number" => "1",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "printed_total_taxable" => 1000,
            "line_items" => [
              %{
                "printed_taxable_value" => 900,
                "cgst_rate" => 9,
                "cgst_amount" => 81,
                "sgst_rate" => 9,
                "sgst_amount" => 81
              }
            ]
          }
        })

      %{invoices: [invoice], header: Gstr1.production_header("33AEWPH4158J1Z3", "2026-05")}
    end

    test "a correction to a flagged scalar field is applied and re-derived", %{
      invoices: invoices,
      header: header
    } do
      # The printed total disagrees with the line sum, so the engine flags
      # `line_items`, authorizing corrections to its scalar sub-paths.
      flagged = Gstr1.flagged_fields(invoices, Gstr1.validation_issues(invoices))
      assert MapSet.member?(flagged, {"1", "line_items"})

      fix = %{
        "verb" => "correct_field",
        "target" => "1",
        "payload" => %{
          "field" => "line_items[0].taxable_value",
          "from" => 900,
          "to" => 1000
        }
      }

      worked = Workings.materialize(invoices, [fix], header)

      assert worked.silent_errors == []
      assert [%{"line_items" => [%{"taxable_value" => 1000}]}] = worked.invoices
    end

    test "an aggregate flagged field cannot replace the line items", %{
      invoices: invoices,
      header: header
    } do
      fix = %{
        "verb" => "correct_field",
        "target" => "1",
        "payload" => %{
          "field" => "line_items",
          "to" => [%{"taxable_value" => 1000, "cgst_rate" => 9, "cgst_amount" => 90}]
        }
      }

      worked = Workings.materialize(invoices, [fix], header)

      assert length(worked.silent_errors) == 1
      assert [%{"line_items" => [%{"taxable_value" => 900}]}] = worked.invoices
    end

    test "a correction reaches the derived return, not just the invoice", %{
      invoices: invoices,
      header: header
    } do
      fix = %{
        "verb" => "correct_field",
        "target" => "1",
        "payload" => %{
          "field" => "line_items[0].taxable_value",
          "from" => 900,
          "to" => 1000
        }
      }

      before = Gstr1.derive(invoices, header)
      worked = Workings.materialize(invoices, [fix], header)

      assert bucket_txval(before) == 900
      assert bucket_txval(worked.derived) == 1000
    end

    test "a correction to an unflagged field never enters the month", %{
      invoices: invoices,
      header: header
    } do
      fix = %{
        "verb" => "correct_field",
        "target" => "1",
        "payload" => %{"field" => "buyer_name", "from" => nil, "to" => "Someone Else"}
      }

      worked = Workings.materialize(invoices, [fix], header)

      assert length(worked.silent_errors) == 1

      assert [%{"buyer_name" => nil}] = worked.invoices,
             "materialize/4 refuses silent corrections where the retired script applied and reported them"
    end
  end

  defp bucket_txval(derived) do
    get_in(derived, [
      "b2b",
      Access.at(0),
      "inv",
      Access.at(0),
      "itms",
      Access.at(0),
      "itm_det",
      "txval"
    ])
  end

  describe "evaluable/0" do
    test "is the sales months that have a filed return to score against" do
      names = Eval.evaluable()

      assert "caltech-2025-11-sales" in names
      refute Enum.any?(names, &String.contains?(&1, "purchase"))
    end
  end

  describe "filed_return/2" do
    test "finds the committed portal JSON for a real month" do
      assert {:ok, %{"gstin" => "33BPBPK1081A1ZO"}} = Eval.filed_return("caltech", "2025-11")
    end

    test "names the month when there is no filed return" do
      assert {:error, {:no_filed_return, "nobody", "1999-01"}} =
               Eval.filed_return("nobody", "1999-01")
    end
  end

  describe "segmentation truth" do
    test "records the Breeze November sales continuation and thirteen standalone invoices" do
      assert {:ok, truth} = Segmentation.truth("breeze-2025-11-sales")
      assert length(truth["segments"]) == 14
      assert hd(truth["segments"])["pages"] == [1, 2]
      assert Enum.map(tl(truth["segments"]), & &1["pages"]) == Enum.map(3..15, &[&1])
    end
  end
end
