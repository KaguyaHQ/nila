defmodule Nila.Gst.Sales.ReviewTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Review

  test "builds invoice scopes in register order and counts every actionable target" do
    review = Review.build(workings())

    assert Enum.map(review.all, & &1.source_id) == ~w(source-c source-a source-b)
    assert Enum.map(review.needs_you, & &1.source_id) == ~w(source-c source-a)

    multi_issue = Enum.find(review.all, &(&1.source_id == "source-a"))

    assert multi_issue.open_actionable_targets == [
             "source-a:printed_tax_mismatch",
             "source-a:furniture_row_with_values",
             "source-a:hsn_inferred_code"
           ]

    assert multi_issue.state == :needs_you

    assert Enum.find(review.all, &(&1.source_id == "source-b")).state == :settled
    assert Enum.find(review.all, &(&1.source_id == "source-c")).state == :needs_you

    assert review.progress == %{completed: 1, open: 4, total: 5}
    assert review.month_issue_count == 1
  end

  test "scope selection and navigation do not wrap and do not alter progress" do
    review = Review.build(workings())

    assert Review.select(review, :needs_you).source_id == "source-c"
    assert Review.select(review, :all, "source-b").source_id == "source-b"
    assert Review.select(review, :needs_you, "source-b").source_id == "source-c"

    assert Review.previous(review, :all, "source-c") == nil
    assert Review.next(review, :all, "source-c").source_id == "source-a"
    assert Review.previous(review, :all, "source-b").source_id == "source-a"
    assert Review.next(review, :all, "source-b") == nil
    assert Review.previous(review, :needs_you, "source-c") == nil
    assert Review.next(review, :needs_you, "source-c").source_id == "source-a"
    assert Review.previous(review, :needs_you, "source-a").source_id == "source-c"
    assert Review.next(review, :needs_you, "source-a") == nil

    assert Review.route_state(review, "source-a", nil) == %{scope: :needs_you, item: "source-a"}
    assert Review.route_state(review, "source-b", nil) == %{scope: :all, item: "source-b"}
    assert Review.route_state(review, "unknown", nil) == %{scope: :needs_you, item: "source-c"}

    clean_workings =
      update_in(workings().issues, fn issues ->
        Enum.map(issues, &Map.put(&1, "status", "resolved"))
      end)

    assert Review.route_state(Review.build(clean_workings), nil, :needs_you) == %{
             scope: :all,
             item: "source-c"
           }

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

  test "credit-note treatment keeps portal values positive and presents negative liability" do
    note = %{
      "id" => "source-cn",
      "document_type" => "credit_note",
      "invoice_number" => "03/2024-25",
      "buyer_gstin" => "33AABCP9487A1ZG",
      "line_items" => []
    }

    derived = %{
      "cdnr" => [
        %{
          "ctin" => "33AABCP9487A1ZG",
          "nt" => [
            %{
              "nt_num" => "03/2024-25",
              "ntty" => "C",
              "inv_typ" => "R",
              "pos" => "33",
              "itms" => [
                %{
                  "itm_det" => %{
                    "txval" => 743_125,
                    "iamt" => 0,
                    "camt" => 66_881.25,
                    "samt" => 66_881.25,
                    "csamt" => 0
                  }
                }
              ]
            }
          ]
        }
      ]
    }

    snapshot = Review.treatment_snapshot(note, derived)

    assert snapshot["table"] == "cdnr"
    assert snapshot["category"] == "C"
    assert snapshot["taxable_amount"] == -743_125
    assert snapshot["tax_amount"] == -133_762.5

    assert snapshot["tax_amounts"] == %{
             "igst" => 0,
             "cgst" => -66_881.25,
             "sgst" => -66_881.25,
             "cess" => 0
           }
  end

  test "debit-note treatment keeps portal values and liability effect positive" do
    note = %{
      "id" => "source-dn",
      "document_type" => "debit_note",
      "invoice_number" => "CDN-000001",
      "buyer_gstin" => "29AAVCS8021P1ZB",
      "line_items" => []
    }

    derived = %{
      "cdnr" => [
        %{
          "ctin" => "29AAVCS8021P1ZB",
          "nt" => [
            %{
              "nt_num" => "CDN-000001",
              "ntty" => "D",
              "inv_typ" => "R",
              "pos" => "29",
              "itms" => [
                %{
                  "itm_det" => %{
                    "txval" => 10_000,
                    "iamt" => 1_800,
                    "camt" => 0,
                    "samt" => 0,
                    "csamt" => 0
                  }
                }
              ]
            }
          ]
        }
      ]
    }

    snapshot = Review.treatment_snapshot(note, derived)

    assert snapshot["table"] == "cdnr"
    assert snapshot["category"] == "D"
    assert snapshot["tax_head"] == "igst"
    assert snapshot["taxable_amount"] == 10_000
    assert snapshot["tax_amount"] == 1_800
    assert snapshot["tax_amounts"] == %{"igst" => 1_800, "cgst" => 0, "sgst" => 0, "cess" => 0}
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
        issue("source-a", "furniture_row_with_values", "open"),
        issue("source-b", "grand_total_mismatch", "resolved"),
        issue("source-c", "invalid_gstin", "open"),
        issue("source-a", "hsn_inferred_code", "open"),
        %{
          "invoice" => nil,
          "code" => "pages_unaccounted",
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
