defmodule Nila.Gst.Filing.Gstr3bInvariantsTest do
  @moduledoc """
  The two properties Table 4 must hold whatever the month looks like:

    * **4C is never negative.** A negative net ITC is not a return — `setoff/3`
      feeds it to `use_credit`, where `min(payable, negative)` *raises* the
      payable and manufactures a cash demand out of a month that owed nothing.
    * **4C ties to the ITC bridge's claimable figure**, once the decisions that
      gate the signature are settled. The two are computed by different modules
      from different projections, and when they disagree the reviewer approves a
      number the portal never receives.

  Both were false before: a block is staked at the *books* row's tax while the
  ceiling holds the *2B's*, and `ItcPosition` clamped the difference while the
  return did not.
  """
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.{Gstr3b, ItcPosition}

  @heads ~w(igst cgst sgst)
  @no_liability %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}

  defp total(heads), do: @heads |> Enum.map(&(heads[&1] || 0)) |> Enum.sum()

  defp gstr2b(inum, tax, opts \\ []) do
    %{
      "vendor_gstin" => "33AAACS9999A1Z9",
      "vendor_name" => "Portal Vendor",
      "invoice_number" => inum,
      "taxable_paise" => Keyword.get(opts, :taxable, tax * 5),
      "tax_paise" => %{"igst" => tax, "cgst" => 0, "sgst" => 0}
    }
  end

  defp row(id, inum, tax, opts) do
    %{
      "id" => id,
      "bucket" => Keyword.fetch!(opts, :bucket),
      "vendor_gstin" => "33AAACS9999A1Z9",
      "vendor_name" => "Portal Vendor",
      "invoice_number" => inum,
      "taxable_paise" => tax * 5,
      "igst_paise" => tax,
      "cgst_paise" => 0,
      "sgst_paise" => 0,
      "flags" => Keyword.get(opts, :flags, [])
    }
  end

  defp flag(code), do: %{"code" => code, "section" => "s.17(5)", "reason" => "test"}

  defp empty_recon,
    do: %{
      "matched" => [],
      "value_mismatch" => [],
      "needs_human" => [],
      "in_2b_not_books" => [],
      "in_books_not_2b" => []
    }

  defp assemble(recon, rows, decisions) do
    itc = ItcPosition.compute(recon, rows, decisions)
    {itc, Gstr3b.assemble(@no_liability, recon, itc)}
  end

  defp assert_sound({itc, assembled}) do
    net = total(assembled["itc"]["net_itc_4c"])

    assert net >= 0, "4C filed a negative net ITC of #{net}"

    assert assembled["setoff_61"]["cash_total"] >= 0,
           "a month with no outward liability was made to pay cash"

    # Pending decisions gate the signature, so at a signable month they are zero
    # and the two figures must be the same number.
    if itc["pending_decision_paise"] == 0 do
      assert net == itc["claimable_paise"],
             "4C filed #{net} while the bridge showed #{itc["claimable_paise"]}"
    end

    {itc, assembled}
  end

  test "three scans of one bill the portal reported once" do
    rows =
      for i <- 1..3,
          do:
            row("r#{i}", "DUP-1", 100_000, bucket: "matched", flags: [flag("duplicate_invoice")])

    recon = %{empty_recon() | "matched" => [%{"gstr2b" => gstr2b("DUP-1", 100_000)}]}
    decisions = %{ItcPosition.block_id("r1", "duplicate_invoice") => "block_itc"}

    {itc, assembled} = assert_sound(assemble(recon, rows, decisions))

    # The over-claim this block exists to prevent was already prevented by the
    # ceiling: the portal reported the invoice once, so the excess copies were
    # never in the claim and blocking them withholds nothing.
    assert itc["blocked_in_ceiling_paise"] == 0
    assert itc["blocked_outside_ceiling_paise"] == 200_000
    assert total(assembled["itc"]["net_itc_4c"]) == 100_000
  end

  test "a blocked row whose books tax exceeds the 2B's" do
    rows = [
      row("r1", "VM-1", 500_000, bucket: "value_mismatch", flags: [flag("personal_expense_17_5")])
    ]

    recon = %{
      empty_recon()
      | "value_mismatch" => [%{"gstr2b" => gstr2b("VM-1", 100_000), "books" => hd(rows)}]
    }

    decisions = %{ItcPosition.block_id("r1", "personal_expense_17_5") => "block_itc"}

    {_itc, assembled} = assert_sound(assemble(recon, rows, decisions))

    # The return avails the 2B's figure, so it can only reverse the 2B's figure.
    assert total(assembled["itc"]["reversed_4b1"]) == 100_000
    assert total(assembled["itc"]["net_itc_4c"]) == 0
  end

  test "a books-only bill blocked under 17(5) leaves the claim alone" do
    rows = [
      row("r1", "BO-1", 100_000,
        bucket: "in_books_not_2b",
        flags: [flag("personal_expense_17_5")]
      ),
      row("r2", "M-1", 300_000, bucket: "matched")
    ]

    recon = %{empty_recon() | "matched" => [%{"gstr2b" => gstr2b("M-1", 300_000)}]}
    decisions = %{ItcPosition.block_id("r1", "personal_expense_17_5") => "block_itc"}

    {_itc, assembled} = assert_sound(assemble(recon, rows, decisions))
    assert total(assembled["itc"]["net_itc_4c"]) == 300_000
  end

  test "an ordinary blocked row still reverses in full" do
    rows = [row("r1", "M-1", 100_000, bucket: "matched", flags: [flag("personal_expense_17_5")])]
    recon = %{empty_recon() | "matched" => [%{"gstr2b" => gstr2b("M-1", 100_000)}]}
    decisions = %{ItcPosition.block_id("r1", "personal_expense_17_5") => "block_itc"}

    {_itc, assembled} = assert_sound(assemble(recon, rows, decisions))

    assert total(assembled["itc"]["reversed_4b1"]) == 100_000
    assert total(assembled["itc"]["net_itc_4c"]) == 0
  end

  test "a clean month is unaffected" do
    rows = [row("r1", "M-1", 100_000, bucket: "matched")]
    recon = %{empty_recon() | "matched" => [%{"gstr2b" => gstr2b("M-1", 100_000)}]}

    {_itc, assembled} = assert_sound(assemble(recon, rows, %{}))
    assert total(assembled["itc"]["net_itc_4c"]) == 100_000
  end
end
