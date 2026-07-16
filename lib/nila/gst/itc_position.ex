defmodule Nila.Gst.ItcPosition do
  @moduledoc """
  The claimable-ITC position for a worked month: the 2B ceiling, the credits
  Nila recommends blocking (with the law section and the tax at stake), and the
  claimable total after the human's block/allow decisions.

  The posture is north-star: Nila takes a position (recommends the blocks) but
  commits nothing silently — every recommended block is a line the human
  confirms or overrides, and the claimable number moves as they do. Pure: rows
  + decisions in, position out. The register rows already carry `flags` and the
  per-row tax, so this reads from the same projection every surface uses.

  ITC law shape encoded here:

    * The 2B is the ceiling — you cannot claim credit the vendor didn't report.
      `ceiling_paise` is the total tax across all GSTR-2B rows the engine saw
      (matched + value_mismatch + awaiting-in-needs_human + 2B-only), matching
      `MonthPack.itc`'s `all_2b` so the two cannot drift.
    * Blocked credits reduce what is *claimable* below the ceiling:
      - `personal_expense_17_5` / `gstin_state_mismatch`: the row's full tax is
        ineligible (s.17(5) / inter-state CGST-SGST wrongly charged).
      - `duplicate_invoice`: only the *extra* copies are ineligible — one copy
        is a real bill. A group of N identical scans blocks (N-1) copies' tax.
  """

  @full_block ~w(personal_expense_17_5 gstin_state_mismatch)

  @doc """
  Computes the position from the effective `recon`, the register `rows`, and the
  block/allow `decisions` map (`%{block_id => "block_itc" | "allow_itc"}`).

  Returns:

      %{
        "ceiling_paise"    => integer,   # 2B ITC ceiling (ties to filed 3B)
        "recommended_paise"=> integer,   # tax Nila recommends blocking
        "blocked_paise"    => integer,   # tax the human has confirmed blocked
        "claimable_paise"  => integer,   # ceiling - blocked
        "blocks" => [%{
          "block_id", "code", "section", "vendor", "invoice_number",
          "tax_paise", "reason", "state" => "recommended"|"blocked"|"allowed"
        }]
      }
  """
  def compute(recon, rows, decisions \\ %{}) do
    ceiling = ceiling_paise(recon)
    blocks = Enum.map(block_candidates(rows), &decide(&1, decisions))
    blocked = blocks |> Enum.filter(&(&1["state"] == "blocked")) |> sum_tax()
    recommended = blocks |> Enum.reject(&(&1["state"] == "allowed")) |> sum_tax()

    %{
      "ceiling_paise" => ceiling,
      "recommended_paise" => recommended,
      "blocked_paise" => blocked,
      "claimable_paise" => ceiling - blocked,
      "blocks" => blocks
    }
  end

  @doc "The stable id a block/allow resolution targets for one flagged row."
  def block_id(row_id, code), do: "#{row_id}:#{code}"

  # The 2B ITC ceiling — reproduced from recon exactly as MonthPack.itc's all_2b
  # so the two never diverge (validated to tie to the filed 3B).
  def ceiling_paise(recon) do
    matched = tax_of(recon["matched"]) + tax_of(recon["value_mismatch"])
    in_2b_only = recon["in_2b_not_books"] |> Enum.map(&tax_sum(&1["gstr2b"] || &1)) |> Enum.sum()
    matched + in_2b_only + awaiting_2b_tax(recon)
  end

  defp tax_of(entries), do: entries |> Enum.map(&tax_sum(&1["gstr2b"])) |> Enum.sum()

  # 2B invoices routed to human, deduped (an ambiguous pair lists the same
  # candidate from both books rows). Mirrors MonthPack.awaiting_2b_tax.
  defp awaiting_2b_tax(recon) do
    recon["needs_human"]
    |> Enum.flat_map(fn e ->
      case e["candidates"] |> List.wrap() |> List.first() || e["gstr2b"] do
        nil -> []
        g -> [g]
      end
    end)
    |> Enum.uniq_by(fn g -> {g["vendor_gstin"], g["invoice_number"]} end)
    |> Enum.map(&tax_sum/1)
    |> Enum.sum()
  end

  # The block candidates for a month: one per full-block flag (personal / state)
  # staking the row's whole tax, plus ONE per duplicate GROUP staking the excess
  # (N-1 copies), never one per copy — a group is a single accounting decision
  # ("keep one, drop the rest").
  defp block_candidates(rows) do
    full =
      for row <- rows, flag <- row["flags"] || [], flag["code"] in @full_block do
        %{
          "block_id" => block_id(row["id"], flag["code"]),
          "code" => flag["code"],
          "section" => flag["section"],
          "vendor" => row["vendor_name"],
          "invoice_number" => row["invoice_number"],
          "tax_paise" => row_tax(row),
          "reason" => flag["reason"]
        }
      end

    full ++ duplicate_blocks(rows)
  end

  # One block per duplicate group, keyed on the group's kept row, staking the
  # excess (N-1) copies' tax. The excess is what claiming every copy would
  # over-claim; keeping one copy is a real bill.
  defp duplicate_blocks(rows) do
    rows
    |> Enum.filter(fn r -> Enum.any?(r["flags"] || [], &(&1["code"] == "duplicate_invoice")) end)
    |> Enum.group_by(fn r -> {r["vendor_gstin"], norm(r["invoice_number"])} end)
    |> Enum.map(fn {_key, group} ->
      keep = Enum.min_by(group, & &1["id"])
      n = length(group)
      dup_flag = Enum.find(keep["flags"], &(&1["code"] == "duplicate_invoice"))

      %{
        "block_id" => block_id(keep["id"], "duplicate_invoice"),
        "code" => "duplicate_invoice",
        "section" => dup_flag["section"],
        "vendor" => keep["vendor_name"],
        "invoice_number" => keep["invoice_number"],
        "tax_paise" => row_tax(keep) * (n - 1),
        "reason" => dup_flag["reason"]
      }
    end)
  end

  defp decide(block, decisions) do
    state =
      case Map.get(decisions, block["block_id"]) do
        "block_itc" -> "blocked"
        "allow_itc" -> "allowed"
        _ -> "recommended"
      end

    Map.put(block, "state", state)
  end

  defp sum_tax(blocks), do: blocks |> Enum.map(& &1["tax_paise"]) |> Enum.sum()

  defp row_tax(row),
    do: (row["cgst_paise"] || 0) + (row["sgst_paise"] || 0) + (row["igst_paise"] || 0)

  defp tax_sum(inv), do: (inv["tax_paise"] || %{}) |> Map.values() |> Enum.sum()
  defp norm(inum), do: inum |> to_string() |> String.trim() |> String.upcase()
end
