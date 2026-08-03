defmodule Nila.Gst.Sales.ReviewTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Review

  test "builds invoice scopes in source-register order and counts decision targets" do
    review = Review.build(workings())

    assert Enum.map(review.all, & &1.source_id) == ~w(source-c source-a source-b)
    assert Enum.map(review.needs_you, & &1.source_id) == ["source-a"]

    challenged = Enum.find(review.all, &(&1.source_id == "source-a"))

    assert challenged.open_decision_targets == [
             "source-a:printed_tax_mismatch",
             "treatment|source-a"
           ]

    assert challenged.state == :needs_you

    assert Enum.find(review.all, &(&1.source_id == "source-b")).state == :settled
    assert Enum.find(review.all, &(&1.source_id == "source-c")).state == :unreviewed

    assert review.progress == %{completed: 1, open: 2, total: 3}
    assert review.month_issue_count == 1
  end

  test "scope selection and navigation do not wrap and do not alter progress" do
    review = Review.build(workings())

    assert Review.select(review, :needs_you).source_id == "source-a"
    assert Review.select(review, :all, "source-b").source_id == "source-b"
    assert Review.select(review, :needs_you, "source-b").source_id == "source-a"

    assert Review.previous(review, :all, "source-c") == nil
    assert Review.next(review, :all, "source-c").source_id == "source-a"
    assert Review.previous(review, :all, "source-b").source_id == "source-a"
    assert Review.next(review, :all, "source-b") == nil
    assert Review.previous(review, :needs_you, "source-a") == nil
    assert Review.next(review, :needs_you, "source-a") == nil

    assert review.progress == Review.build(workings()).progress
  end

  test "treatment_snapshot freezes the derived category, place, heads, and amounts" do
    [invoice | _] = workings().active_invoices
    snapshot = Review.treatment_snapshot(invoice, workings().derived)

    assert snapshot == %{
             "source_id" => "source-c",
             "invoice_number" => "30/2025-26",
             "buyer_gstin" => "33AABCP9487A1ZG",
             "table" => "b2b",
             "category" => "R",
             "place_of_supply" => "33",
             "tax_head" => "cgst_sgst",
             "taxable_amount" => 3_000,
             "tax_amount" => 540,
             "tax_amounts" => %{"igst" => 0, "cgst" => 270, "sgst" => 270, "cess" => 0}
           }
  end

  defp workings do
    invoices = [
      invoice("source-c", "30/2025-26"),
      invoice("source-a", "10/2025-26"),
      invoice("source-b", "20/2025-26"),
      invoice("source-without-treatment", "40/2025-26")
    ]

    %{
      active_invoices: invoices,
      issues: [
        issue("source-a", "printed_tax_mismatch", "open"),
        %{
          "invoice" => "10/2025-26",
          "source_id" => "source-a",
          "code" => "treatment_challenged",
          "target" => "treatment|source-a",
          "level" => "required",
          "status" => "open"
        },
        issue("source-b", "grand_total_mismatch", "resolved"),
        issue("source-c", "invalid_gstin", "open"),
        %{
          "invoice" => nil,
          "code" => "completeness_unconfirmed",
          "target" => "exports|month-scope",
          "level" => "required",
          "status" => "open"
        }
      ],
      derived: %{
        "b2b" => [
          %{
            "ctin" => "33AABCP9487A1ZG",
            "inv" => [
              treatment("10/2025-26", 1_000),
              treatment("20/2025-26", 2_000),
              treatment("30/2025-26", 3_000)
            ]
          }
        ]
      }
    }
  end

  defp invoice(id, number) do
    %{
      "id" => id,
      "invoice_number" => number,
      "buyer_gstin" => "33AABCP9487A1ZG",
      "line_items" => []
    }
  end

  defp issue(source_id, code, status) do
    %{
      "invoice" => source_id,
      "source_id" => source_id,
      "code" => code,
      "level" => "required",
      "status" => status
    }
  end

  defp treatment(number, taxable) do
    %{
      "inum" => number,
      "inv_typ" => "R",
      "pos" => "33",
      "itms" => [
        %{
          "itm_det" => %{
            "txval" => taxable,
            "iamt" => 0,
            "camt" => taxable * 9 / 100,
            "samt" => taxable * 9 / 100,
            "csamt" => 0
          }
        }
      ]
    }
  end
end
