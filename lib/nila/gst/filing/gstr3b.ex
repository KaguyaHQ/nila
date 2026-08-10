defmodule Nila.Gst.Filing.Gstr3b do
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
      4B(1), duplicate-excess and state-mismatch in 4B(2). Credit the client
      has attested they hold no tax invoice for (s.16(2)(a)) also reverses in
      4B(2) — 4A(5) is auto-populated from the 2B on the portal, so the claim
      is withheld by reversing, not by shrinking what was availed. Only blocks
      *inside* the ceiling reverse; a books bill the 2B never reported was
      never availed. 4C = 4A − 4B, and at sign-off 4C ties to the ITC bridge's
      claimable figure.
    * **6.1** — payment. Whole-rupee rounding (the portal's convention), then
      Rule 88A set-off: IGST credit first against IGST, spillover to CGST then
      SGST; CGST credit to CGST then IGST; SGST credit to SGST then IGST;
      never CGST↔SGST. RCM liability is cash-only — credit cannot pay it.

  Deliberately out of scope (single-month engine): Rule 37 temporary
  reversals / 4D(1) reclaims need cross-month state; zero-rated / nil-rated /
  exempt outward (3.1 b/c/e) need data no current client has.
  """

  alias Nila.Gst.Filing.ItcPosition
  alias Nila.Gst.Purchase.Workings
  alias Nila.Gst.Sales.Gstr1

  @heads ~w(igst cgst sgst)
  @zero %{"igst" => 0, "cgst" => 0, "sgst" => 0}
  @reversal_4b1 ~w(personal_expense_17_5)

  @doc """
  Assembles the return.

    * `liability` — 3.1(a) as `%{"txval" | "igst" | "cgst" | "sgst" => paise}`
    * `recon` — the effective recon (RCM rows and the ITC ceiling live here)
    * `itc` — `ItcPosition.compute/3` output (blocks carry `tax_heads`/`state`)
  """
  def assemble(liability, recon, itc), do: assemble(liability, recon, itc, [])

  def assemble(liability, recon, itc, interstate_unregistered) do
    {rcm_txval, rcm_tax} = rcm_position(recon)
    all_other_4a5 = subtract(ItcPosition.ceiling_heads(recon), rcm_tax)

    {reversed_4b1, blocked_4b2} =
      cap_reversals(
        blocked_heads(itc, &(&1 in @reversal_4b1)),
        blocked_heads(itc, &(&1 not in @reversal_4b1)),
        itc
      )

    reversed_4b2 = add(blocked_4b2, itc["unsubstantiated_withheld_heads"] || @zero)

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
      "interstate_32" => %{
        "unregistered" => interstate_unregistered,
        "composition" => [],
        "uin" => []
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
  3.1(a) from a derived GSTR-1 (`Nila.Gst.Sales.Gstr1.derive/2` output, rupee
  floats) — sums every rate bucket into head-wise paise.
  """
  def liability_from_gstr1(derived) do
    buckets = derived |> Gstr1.signed_details() |> Enum.map(& &1.detail)

    Enum.reduce(buckets, Map.put(@zero, "txval", 0), fn det, acc ->
      acc
      |> bump("txval", det["txval"])
      |> bump("igst", det["iamt"])
      |> bump("cgst", det["camt"])
      |> bump("sgst", det["samt"])
    end)
  end

  @doc "Table 3.2 interstate supplies to unregistered persons, grouped by POS in paise."
  def interstate_unregistered_from_gstr1(derived) do
    b2cs =
      for row <- derived["b2cs"] || [], row["sply_ty"] == "INTER" do
        %{"pos" => row["pos"], "txval" => row["txval"] || 0, "igst" => row["iamt"] || 0}
      end

    b2cl =
      for block <- derived["b2cl"] || [], invoice <- block["inv"] || [] do
        details = for item <- invoice["itms"] || [], do: item["itm_det"] || %{}

        %{
          "pos" => block["pos"],
          "txval" => Enum.sum(Enum.map(details, &(&1["txval"] || 0))),
          "igst" => Enum.sum(Enum.map(details, &(&1["iamt"] || 0)))
        }
      end

    (b2cs ++ b2cl)
    |> Enum.group_by(& &1["pos"])
    |> Enum.map(fn {pos, rows} ->
      %{
        "pos" => pos,
        "txval" => rows |> Enum.map(& &1["txval"]) |> Enum.sum() |> rupees_to_paise(),
        "igst" => rows |> Enum.map(& &1["igst"]) |> Enum.sum() |> rupees_to_paise()
      }
    end)
    |> Enum.sort_by(& &1["pos"])
  end

  @doc "Whether Table 3.1(a) contains a negative value this assembler cannot file safely yet."
  def negative_outward_liability?(%{"liability_31" => %{"a" => liability}}) do
    Enum.any?(~w(txval igst cgst sgst), &((liability[&1] || 0) < 0))
  end

  def negative_outward_liability?(_gstr3b), do: false

  # -- reverse charge -------------------------------------------------------

  defp rcm_position(recon) do
    rows = recon |> Workings.gstr2b_invoices() |> Enum.filter(& &1["reverse_charge"])

    {
      rows |> Enum.map(&(&1["taxable_paise"] || 0)) |> Enum.sum(),
      rows |> Enum.map(&(&1["tax_paise"] || %{})) |> ItcPosition.sum_heads()
    }
  end

  # -- ITC reversals --------------------------------------------------------

  # `ItcPosition.partition/3` clamps the blocked figure to what the ceiling can
  # actually hold — a block is staked at the books row's tax, and on a
  # value-mismatch row the books can exceed the 2B figure the return actually
  # avails. The return has to honour the same clamp: reversing the unclamped
  # amount took 4B above 4A, filed a negative 4C, and `setoff/3` then turned
  # that negative credit into a cash demand out of a month that owed nothing.
  #
  # 4B(1) is satisfied first because s.17(5) ineligibility is the harder
  # statement; whatever room is left goes to 4B(2).
  defp cap_reversals(reversed_4b1, reversed_4b2, itc) do
    cap = itc["blocked_in_ceiling_paise"]
    raw = heads_total(reversed_4b1) + heads_total(reversed_4b2)

    if is_integer(cap) and raw > cap do
      capped_4b1 = ItcPosition.allocate(reversed_4b1, min(heads_total(reversed_4b1), cap))
      {capped_4b1, ItcPosition.allocate(reversed_4b2, cap - heads_total(capped_4b1))}
    else
      {reversed_4b1, reversed_4b2}
    end
  end

  defp heads_total(heads), do: @heads |> Enum.map(&(heads[&1] || 0)) |> Enum.sum()

  # Only blocks inside the 2B ceiling can be reversed: 4A(5) availed the ceiling,
  # so a books bill the portal never reported was never availed and there is
  # nothing to reverse. Reversing it anyway dropped 4C below what 4A availed
  # while the ITC bridge — which excludes the same blocks (`ItcPosition`) — was
  # unchanged, so the filed and displayed claims silently disagreed.
  defp blocked_heads(itc, code_filter) do
    itc["blocks"]
    |> Enum.filter(&(&1["state"] == "blocked" and &1["in_ceiling"] and code_filter.(&1["code"])))
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
  defp rupees_to_paise(rupees), do: round(rupees * 100)

  defp add(a, b), do: Map.new(@heads, fn h -> {h, a[h] + b[h]} end)
  defp subtract(a, b), do: Map.new(@heads, fn h -> {h, a[h] - b[h]} end)

  defp bump(acc, key, value) when is_number(value),
    do: Map.update!(acc, key, &(&1 + round(value * 100)))

  defp bump(acc, _key, _value), do: acc
end
