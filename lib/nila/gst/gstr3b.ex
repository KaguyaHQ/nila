defmodule Nila.Gst.Gstr3b do
  @moduledoc """
  GSTR-3B assembly: the monthly summary return, computed from the two heads
  that already exist — outward liability (GSTR-1 derivation) and the ITC
  position (2B reconciliation + block decisions) — plus reverse-charge rows
  read straight off the GSTR-2B.

  Pure and paise-integer throughout, like the rest of the engine. The output
  shape mirrors the filed-3B fixture (`liability_31` / `itc` / `setoff_61`) so
  a tie-out against a real filed return is a deep compare, not a translation.

  Form shape encoded here:

    * **3.1(a)** — outward taxable supplies. Comes in as `liability`, either
      from `liability_from_gstr1/1` (sales head) or transcribed filed numbers.
    * **3.1(d)** — inward supplies liable to reverse charge. Derived from 2B
      rows with `reverse_charge` — the vendor reported the supply, the client
      owes the tax in cash and earns the matching credit in 4A(3).
    * **Table 4** — 4A(3) RCM credit, 4A(5) all other ITC (the 2B ceiling
      minus RCM), 4B reversals from *human-confirmed* blocks only (Nila
      recommends; the return moves on confirmation): section 17(5) blocks in
      4B(1), duplicate-excess and state-mismatch in 4B(2). 4C = 4A − 4B.
    * **6.1** — payment. Whole-rupee rounding (the portal's convention), then
      Rule 88A set-off: IGST credit first against IGST, spillover to CGST then
      SGST; CGST credit to CGST then IGST; SGST credit to SGST then IGST;
      never CGST↔SGST. RCM liability is cash-only — credit cannot pay it.

  Deliberately out of scope (single-month engine): Rule 37 temporary
  reversals / 4D(1) reclaims need cross-month state; zero-rated / nil-rated /
  exempt outward (3.1 b/c/e) need data no current client has.
  """

  alias Nila.Gst.{ItcPosition, Workings}

  @heads ~w(igst cgst sgst)
  @zero %{"igst" => 0, "cgst" => 0, "sgst" => 0}
  @reversal_4b1 ~w(personal_expense_17_5)

  @doc """
  Assembles the return.

    * `liability` — 3.1(a) as `%{"txval" | "igst" | "cgst" | "sgst" => paise}`
    * `recon` — the effective recon (RCM rows and the ITC ceiling live here)
    * `itc` — `ItcPosition.compute/3` output (blocks carry `tax_heads`/`state`)
  """
  def assemble(liability, recon, itc) do
    {rcm_txval, rcm_tax} = rcm_position(recon)
    all_other_4a5 = subtract(ItcPosition.ceiling_heads(recon), rcm_tax)
    reversed_4b1 = blocked_heads(itc, &(&1 in @reversal_4b1))
    reversed_4b2 = blocked_heads(itc, &(&1 not in @reversal_4b1))

    net_itc_4c =
      rcm_tax
      |> add(all_other_4a5)
      |> subtract(reversed_4b1)
      |> subtract(reversed_4b2)

    %{
      "liability_31" => %{
        "a" => Map.put(liability, "txval", liability["txval"] || 0),
        "d" => Map.put(rcm_tax, "txval", rcm_txval)
      },
      "itc" => %{
        "rcm_4a3" => rcm_tax,
        "all_other_itc_4a5" => all_other_4a5,
        "reversed_4b1" => reversed_4b1,
        "reversed_4b2" => reversed_4b2,
        "net_itc_4c" => net_itc_4c
      },
      "setoff_61" => setoff(liability, rcm_tax, net_itc_4c)
    }
  end

  @doc """
  3.1(a) from a derived GSTR-1 (`Nila.Gst.Gstr1.derive/2` output, rupee
  floats) — sums every rate bucket into head-wise paise.
  """
  def liability_from_gstr1(derived) do
    buckets =
      for party <- derived["b2b"] || [],
          inv <- party["inv"] || [],
          itm <- inv["itms"] || [],
          det = itm["itm_det"],
          do: det

    Enum.reduce(buckets, Map.put(@zero, "txval", 0), fn det, acc ->
      acc
      |> bump("txval", det["txval"])
      |> bump("igst", det["iamt"])
      |> bump("cgst", det["camt"])
      |> bump("sgst", det["samt"])
    end)
  end

  # -- reverse charge -------------------------------------------------------

  defp rcm_position(recon) do
    rows = recon |> Workings.gstr2b_invoices() |> Enum.filter(& &1["reverse_charge"])

    {
      rows |> Enum.map(&(&1["taxable_paise"] || 0)) |> Enum.sum(),
      rows |> Enum.map(&(&1["tax_paise"] || %{})) |> ItcPosition.sum_heads()
    }
  end

  # -- ITC reversals --------------------------------------------------------

  defp blocked_heads(itc, code_filter) do
    itc["blocks"]
    |> Enum.filter(&(&1["state"] == "blocked" and code_filter.(&1["code"])))
    |> Enum.map(& &1["tax_heads"])
    |> ItcPosition.sum_heads()
  end

  # -- 6.1 payment ----------------------------------------------------------

  # Whole-rupee arithmetic, per the portal: payables and credits are rounded
  # before set-off, so cash figures land exactly on the filed numbers.
  defp setoff(liability, rcm_tax, net_itc_4c) do
    payable = Map.new(@heads, fn h -> {h, round_rupee(liability[h] || 0)} end)
    credit = Map.new(@heads, fn h -> {h, round_rupee(net_itc_4c[h])} end)

    {used, remaining} = apply_credit(payable, credit)

    other =
      Map.new(@heads, fn h ->
        {h,
         %{
           "payable" => payable[h],
           "itc_igst" => used[h]["igst"],
           "itc_cgst" => used[h]["cgst"],
           "itc_sgst" => used[h]["sgst"],
           "cash" => remaining[h]
         }}
      end)

    rcm =
      Map.new(@heads, fn h ->
        rounded = round_rupee(rcm_tax[h])
        {h, %{"payable" => rounded, "cash" => rounded}}
      end)

    cash_total =
      Enum.sum(Map.values(remaining)) + Enum.sum(Enum.map(@heads, &rcm[&1]["cash"]))

    %{"other" => other, "rcm" => rcm, "cash_total" => cash_total}
  end

  # Rule 88A order: IGST credit exhausts first (self, then CGST, then SGST);
  # CGST credit pays CGST then IGST; SGST credit pays SGST then IGST. CGST and
  # SGST credit never cross into each other.
  defp apply_credit(payable, credit) do
    used = Map.new(@heads, fn h -> {h, @zero} end)

    {used, payable, credit}
    |> use_credit("igst", "igst")
    |> use_credit("cgst", "igst")
    |> use_credit("sgst", "igst")
    |> use_credit("cgst", "cgst")
    |> use_credit("igst", "cgst")
    |> use_credit("sgst", "sgst")
    |> use_credit("igst", "sgst")
    |> then(fn {used, remaining, _credit} -> {used, remaining} end)
  end

  defp use_credit({used, payable, credit}, target, source) do
    amount = min(payable[target], credit[source])

    {
      update_in(used, [target, source], &(&1 + amount)),
      Map.update!(payable, target, &(&1 - amount)),
      Map.update!(credit, source, &(&1 - amount))
    }
  end

  # -- money ----------------------------------------------------------------

  defp round_rupee(paise), do: round(paise / 100) * 100

  defp add(a, b), do: Map.new(@heads, fn h -> {h, a[h] + b[h]} end)
  defp subtract(a, b), do: Map.new(@heads, fn h -> {h, a[h] - b[h]} end)

  defp bump(acc, key, value) when is_number(value),
    do: Map.update!(acc, key, &(&1 + round(value * 100)))

  defp bump(acc, _key, _value), do: acc
end
