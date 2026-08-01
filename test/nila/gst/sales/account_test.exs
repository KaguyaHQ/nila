defmodule Nila.Gst.Sales.AccountTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Account

  test "ties source artifacts to active extraction and the exact draft tax heads" do
    intra = invoice("1/2026-27", 100, %{cgst: 9, sgst: 9})
    inter = invoice("2/2026-27", 200, %{igst: 36})
    duplicate_copy = Map.put(inter, "id", "d2-i1")

    derived = %{
      "b2b" => [
        %{
          "inv" => [
            %{
              "itms" => [
                %{
                  "itm_det" => %{
                    "txval" => 100,
                    "camt" => 9,
                    "samt" => 9,
                    "iamt" => 0,
                    "csamt" => 0
                  }
                }
              ]
            },
            %{
              "itms" => [
                %{
                  "itm_det" => %{
                    "txval" => 200,
                    "camt" => 0,
                    "samt" => 0,
                    "iamt" => 35.99,
                    "csamt" => 0
                  }
                }
              ]
            }
          ]
        }
      ]
    }

    issues = [
      %{"code" => "bucket_tax_mismatch", "status" => "open"},
      %{"code" => "rounding_variance", "status" => "open", "level" => "info"},
      %{"code" => "grand_total_mismatch", "status" => "resolved"}
    ]

    account =
      Account.summarize(
        [intra, inter, duplicate_copy],
        [intra, inter],
        issues,
        derived,
        %{files: 2, pages_read: nil}
      )

    assert account.source == %{files: 2, pages_read: nil}

    assert account.extraction.documents == 3
    assert account.extraction.active_documents == 2
    assert account.extraction.duplicate_copies == 1
    assert account.extraction.unique_invoice_numbers == 2

    assert account.extraction.totals == %{
             taxable: 300.0,
             igst: 36.0,
             cgst: 9.0,
             sgst: 9.0,
             cess: nil,
             tax: 54.0
           }

    assert account.draft.documents == 2
    assert account.draft.totals.tax == 53.99
    assert account.differences.tax == -0.01
    assert account.differences.cess == nil
    assert account.issues.required_count == 1
    assert account.issues.informational_count == 1
  end

  test "does not invent source page counts or cess for an empty draft" do
    account = Account.summarize([], [], [], nil, %{files: 1, pages_read: nil})

    assert account.source.pages_read == nil
    assert account.draft.documents == 0
    assert account.draft.totals.cess == nil
    assert account.differences.cess == nil
  end

  defp invoice(number, taxable, tax) do
    %{
      "id" => "d1-i#{number}",
      "invoice_number" => number,
      "line_items" => [
        %{
          "taxable_value" => taxable,
          "igst_amount" => tax[:igst],
          "cgst_amount" => tax[:cgst],
          "sgst_amount" => tax[:sgst]
        }
      ]
    }
  end
end
