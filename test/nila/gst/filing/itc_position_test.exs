defmodule Nila.Gst.Filing.ItcPositionTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.ItcPosition

  # A 2B row carrying `tax` total (split cgst/sgst for intrastate).
  defp g2b(tax),
    do: %{"tax_paise" => %{"cgst" => div(tax, 2), "sgst" => div(tax, 2), "igst" => 0}}

  defp row(id, attrs) do
    Map.merge(
      %{
        "id" => id,
        "vendor_name" => "V",
        "vendor_gstin" => "33AAACS1234A1Z9",
        "invoice_number" => id,
        "cgst_paise" => 0,
        "sgst_paise" => 0,
        "igst_paise" => 0,
        "flags" => []
      },
      attrs
    )
  end

  defp flag(code, section \\ nil),
    do: %{"code" => code, "severity" => "review", "section" => section, "reason" => "r"}

  test "ceiling sums all 2B tax across matched, value_mismatch, 2B-only, and awaiting" do
    recon = %{
      "matched" => [%{"gstr2b" => g2b(10_000)}],
      "value_mismatch" => [%{"gstr2b" => g2b(2_000)}],
      "in_2b_not_books" => [%{"gstr2b" => g2b(3_000)}],
      "needs_human" => [%{"candidates" => [g2b(5_000)]}],
      "in_books_not_2b" => []
    }

    pos = ItcPosition.compute(recon, [], %{})
    assert pos["ceiling_paise"] == 20_000
    assert pos["claimable_paise"] == 20_000
    assert pos["blocks"] == []
  end

  test "awaiting 2B tax is deduped (ambiguous pair lists same candidate twice)" do
    g = g2b(5_000)

    recon = %{
      "matched" => [],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "needs_human" => [
        %{"candidates" => [Map.merge(g, %{"vendor_gstin" => "X", "invoice_number" => "1"})]},
        %{"candidates" => [Map.merge(g, %{"vendor_gstin" => "X", "invoice_number" => "1"})]}
      ],
      "in_books_not_2b" => []
    }

    assert ItcPosition.compute(recon, [], %{})["ceiling_paise"] == 5_000
  end

  defp base_recon,
    do: %{
      "matched" => [%{"gstr2b" => g2b(100_000)}],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "needs_human" => [],
      "in_books_not_2b" => []
    }

  test "personal-expense and state-mismatch stake the full row tax, one block each" do
    rows = [
      row("a", %{
        "cgst_paise" => 945,
        "sgst_paise" => 945,
        "flags" => [flag("personal_expense_17_5", "CGST Act 17(5)(g)")]
      }),
      row("b", %{"igst_paise" => 194, "flags" => [flag("gstin_state_mismatch", "IGST Act s.10")]})
    ]

    pos = ItcPosition.compute(base_recon(), rows, %{})
    codes = Enum.map(pos["blocks"], & &1["code"])
    assert codes == ["personal_expense_17_5", "gstin_state_mismatch"]
    assert pos["recommended_paise"] == 1890 + 194
    # nothing confirmed yet: claimable still the full ceiling
    assert pos["claimable_paise"] == 100_000
  end

  test "a duplicate group is ONE block staking the excess (N-1 copies), not per copy" do
    dup = flag("duplicate_invoice")

    rows = [
      row("d1", %{
        "invoice_number" => "254111",
        "cgst_paise" => 157,
        "sgst_paise" => 158,
        "flags" => [dup]
      }),
      row("d2", %{
        "invoice_number" => "254111",
        "cgst_paise" => 157,
        "sgst_paise" => 158,
        "flags" => [dup]
      })
    ]

    pos = ItcPosition.compute(base_recon(), rows, %{})
    assert [block] = pos["blocks"]
    assert block["code"] == "duplicate_invoice"
    # 2 copies of 315 -> block one copy's 315, keep the other
    assert block["tax_paise"] == 315
  end

  test "three identical copies block two copies' worth" do
    dup = flag("duplicate_invoice")

    rows =
      for id <- ["a", "b", "c"],
          do:
            row(id, %{
              "invoice_number" => "X",
              "cgst_paise" => 500,
              "sgst_paise" => 500,
              "flags" => [dup]
            })

    pos = ItcPosition.compute(base_recon(), rows, %{})
    assert [block] = pos["blocks"]
    assert block["tax_paise"] == 2_000
  end

  test "confirming a block reduces claimable; overriding to allow keeps the credit" do
    rows = [
      row("a", %{
        "cgst_paise" => 500,
        "sgst_paise" => 500,
        "flags" => [flag("personal_expense_17_5")]
      })
    ]

    [%{"block_id" => bid}] = ItcPosition.compute(base_recon(), rows, %{})["blocks"]

    blocked = ItcPosition.compute(base_recon(), rows, %{bid => "block_itc"})
    assert blocked["blocked_paise"] == 1_000
    assert blocked["claimable_paise"] == 99_000
    assert [%{"state" => "blocked"}] = blocked["blocks"]

    allowed = ItcPosition.compute(base_recon(), rows, %{bid => "allow_itc"})
    assert allowed["blocked_paise"] == 0
    assert allowed["claimable_paise"] == 100_000
    assert [%{"state" => "allowed"}] = allowed["blocks"]
    # allowed items drop out of the "recommended" total
    assert allowed["recommended_paise"] == 0
  end
end
