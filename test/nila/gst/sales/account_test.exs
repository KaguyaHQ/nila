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

  test "advisories are counted apart from what gates approval, and named by kind" do
    issues = [
      %{"code" => "hsn_new_code", "status" => "open", "level" => "advisory"},
      %{"code" => "hsn_new_code", "status" => "open", "level" => "advisory"},
      %{"code" => "grand_total_mismatch", "status" => "open", "level" => "required"},
      %{"code" => "cess_not_evaluated", "status" => "open", "level" => "required"},
      %{"code" => "invalid_hsn_sac", "status" => "open", "level" => "required"},
      %{"code" => "credit_note_unsupported", "status" => "open", "level" => "blocking"},
      %{"code" => "rounding_variance", "status" => "open", "level" => "info"}
    ]

    account = Account.summarize([], [], issues, nil, %{files: 1, pages_read: nil})

    assert account.issues.required_count == 4
    assert account.issues.advisory_count == 2
    assert account.issues.informational_count == 1

    # The kinds account for everything that gates: the blocker asks for no work
    # but must not vanish from a count that decides whether the month can be
    # signed.
    assert account.issues.by_kind ==
             %{decision: 1, confirmation: 1, correction: 1, blocked: 1}

    assert Enum.sum(Map.values(account.issues.by_kind)) == account.issues.required_count
  end

  test "a legacy snapshot's warning levels are counted by what the code means today" do
    issues = [
      %{"code" => "hsn_new_code", "status" => "open", "level" => "warning"},
      %{"code" => "invalid_hsn_sac", "status" => "open", "level" => "warning"},
      %{"code" => "grand_total_mismatch", "status" => "open"}
    ]

    account = Account.summarize([], [], issues, nil, %{files: 1, pages_read: nil})

    assert account.issues.required_count == 2
    assert account.issues.advisory_count == 1
  end

  test "does not invent source page counts or cess for an empty draft" do
    account = Account.summarize([], [], [], nil, %{files: 1, pages_read: nil})

    assert account.source.pages_read == nil
    assert account.draft.documents == 0
    assert account.draft.totals.cess == nil
    assert account.differences.cess == nil
  end

  describe "the as-printed side of a frozen month" do
    test "a snapshot that never recorded it says so rather than borrowing today's invoices" do
      inv = invoice("1/2026-27", 100, %{cgst: 9, sgst: 9})

      account =
        Account.summarize(
          %{
            source_invoices: [inv],
            active_invoices: [inv],
            printed_active_invoices: nil,
            issues: [],
            derived: nil
          },
          %{files: 1, pages_read: nil}
        )

      # Defaulting to the active invoices made a signed month's reconciliation
      # re-render against whatever the invoice set says now, so what a reviewer
      # signed could change under the signature.
      refute account.printed.recorded?
    end

    test "a month that did record it is believed" do
      inv = invoice("1/2026-27", 100, %{cgst: 9, sgst: 9})

      account =
        Account.summarize(
          %{
            source_invoices: [inv],
            active_invoices: [inv],
            printed_active_invoices: [inv],
            issues: [],
            derived: nil
          },
          %{files: 1, pages_read: nil}
        )

      assert account.printed.recorded?
      assert account.printed.documents == 1
    end
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
