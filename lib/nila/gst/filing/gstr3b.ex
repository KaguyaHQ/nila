defmodule Nila.Gst.Filing.Gstr3b do
  @moduledoc """
  GSTR-3B assembly: the monthly summary return, computed from the two heads
  that already exist — outward liability (GSTR-1 derivation) and the ITC
  position (reviewed current-period treatment) — plus reverse-charge rows
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
    * **Table 4** — current-period claim comes from explicit case treatment,
      including credit carried from earlier periods. Supplier credit notes
      retain their 4B(2) reversal. Credit marked for later is not described as
      a statutory reversal or reclaim event.
    * **6.1** — payment. Whole-rupee rounding (the portal's convention), then
      Rule 88A set-off: IGST credit first against IGST, spillover to CGST then
      SGST; CGST credit to CGST then IGST; SGST credit to SGST then IGST;
      never CGST↔SGST. RCM liability is cash-only — credit cannot pay it.

  Deliberately out of scope: Rule 37 temporary reversals and 4D(1)
  reclaims need statutory event history; zero-rated / nil-rated /
  exempt outward (3.1 b/c/e) need data no current client has.
  """

  alias Nila.Gst.Filing.ItcPosition
  alias Nila.Gst.Money
  alias Nila.Gst.Purchase.Workings
  alias Nila.Gst.Sales.Gstr1

  @heads ~w(igst cgst sgst)
  @itc_heads ~w(igst cgst sgst cess)
  @zero %{"igst" => 0, "cgst" => 0, "sgst" => 0}
  @zero_itc Map.put(@zero, "cess", 0)

  @doc """
  Assembles the return.

    * `liability` — 3.1(a) as `%{"txval" | "igst" | "cgst" | "sgst" => paise}`
    * `recon` — the effective recon (RCM rows and the ITC ceiling live here)
    * `itc` — `ItcPosition.compute/4` output with `current_claim_heads`
  """
  def assemble(liability, recon, itc), do: assemble(liability, recon, itc, [])

  def assemble(liability, recon, itc, interstate_unregistered) do
    {rcm_txval, rcm_tax} = rcm_position(recon)
    assemble_treated(liability, recon, itc, interstate_unregistered, rcm_txval, rcm_tax)
  end

  defp assemble_treated(liability, recon, itc, interstate_unregistered, rcm_txval, rcm_tax) do
    claim = itc["current_claim_heads"]
    credit_notes = ItcPosition.credit_note_reversal_heads(recon)
    # The treatment is the credit being claimed this month, including older
    # carried credit. Deferral is not a statutory reversal or reclaim event.
    # Credit notes retain their existing 4B(2) treatment.
    claimed_rcm =
      Map.new(@itc_heads, fn head -> {head, get_in(itc, ["rcm_claim_heads", head]) || 0} end)

    all_other_4a5 =
      claim
      |> subtract(claimed_rcm)
      |> Map.put("cess", (claim["cess"] || 0) - claimed_rcm["cess"])

    net_itc_4c =
      claim
      |> subtract(credit_notes)
      |> Map.put("cess", (claim["cess"] || 0) - (credit_notes["cess"] || 0))

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
        "rcm_4a3" => claimed_rcm,
        "all_other_itc_4a5" => all_other_4a5,
        "reversed_4b1" => @zero_itc,
        "reversed_4b2" => credit_notes,
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
    buckets = derived |> Map.delete("nil") |> Gstr1.signed_details() |> Enum.map(& &1.detail)

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

    cdnur =
      for note <- derived["cdnur"] || [], note["typ"] == "B2CL" do
        sign = if note["ntty"] == "C", do: -1, else: 1
        details = Enum.map(note["itms"] || [], &(&1["itm_det"] || %{}))

        %{
          "pos" => note["pos"],
          "txval" => sign * Enum.sum(Enum.map(details, &(&1["txval"] || 0))),
          "igst" => sign * Enum.sum(Enum.map(details, &(&1["iamt"] || 0)))
        }
      end

    (b2cs ++ b2cl ++ cdnur)
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

  @doc "Whether supplier credit-note reversals exceed available ITC in this month."
  def negative_net_itc?(%{"itc" => %{"net_itc_4c" => net}}) do
    Enum.any?(@itc_heads, &((net[&1] || 0) < 0))
  end

  def negative_net_itc?(_gstr3b), do: false

  # -- reverse charge -------------------------------------------------------

  defp rcm_position(recon) do
    rows =
      recon
      |> Workings.gstr2b_invoices()
      |> Enum.filter(&(&1["reverse_charge"] == true and &1["document_type"] != "credit_note"))

    {
      rows |> Enum.map(&(&1["taxable_paise"] || 0)) |> Enum.sum(),
      rows |> Enum.map(&(&1["tax_paise"] || %{})) |> ItcPosition.sum_heads()
    }
  end

  # -- 6.1 payment ----------------------------------------------------------

  # Whole-rupee arithmetic, per the portal: payables and credits are rounded
  # before set-off, so cash figures land exactly on the filed numbers.
  defp setoff(liability, rcm_tax, net_itc_4c) do
    payable = Map.new(@heads, fn h -> {h, round_rupee(liability[h] || 0)} end)
    credit = Map.new(@heads, fn h -> {h, max(round_rupee(net_itc_4c[h]), 0)} end)

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
  defp rupees_to_paise(rupees), do: Money.paise(rupees)

  defp subtract(a, b), do: Map.new(@heads, fn h -> {h, a[h] - b[h]} end)

  defp bump(acc, key, value) when is_number(value),
    do: Map.update!(acc, key, &(&1 + Money.paise(value)))

  defp bump(acc, _key, _value), do: acc
end
