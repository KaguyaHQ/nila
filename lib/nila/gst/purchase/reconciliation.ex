defmodule Nila.Gst.Purchase.Reconciliation do
  @moduledoc """
  Purchase reconciliation: books-side invoices (from the extraction pipeline)
  against normalized GSTR-2B invoices (`Nila.Gst.Filing.Gstr2b.parse/1`).

  Pure on purpose — plain maps in, plain maps out, no DB, no IO — same posture
  as `Nila.Gst`, so the matching rules live in one testable place.

  The cardinal rule is **flag, don't guess**: the engine must never emit a
  wrong confident match. Every rung of the matching ladder requires positive
  corroboration before it pairs, and any invoice that could pair with more
  than one counterpart at a rung goes to `needs_human` — the engine never
  picks one. Everything below the confidence line carries a machine-readable
  reason and a drafted next action for the human.

  Ladder, strength ordered, within a vendor-GSTIN group (GSTINs are used only
  when `Nila.Gstin.valid?/1`):

    1. exact invoice number (after light normalization) → `matched` when
       taxable and tax agree within tolerance, `value_mismatch` otherwise;
    2. relaxed invoice number (separators, leading zeros, FY suffixes
       stripped) → `matched` only when **both** date and value corroborate;
       one corroborator → `needs_human`;
    3. value + date agree but invoice numbers disagree → `needs_human`
       (likely typo, never auto-paired);
    4. books invoices without a valid GSTIN: fuzzy vendor name
       (`Nila.Fuzzy`) → `matched` only with exact invoice number **and**
       value in tolerance; anything less → `needs_human`. Never on name alone.

  Residuals land in `in_books_not_2b` / `in_2b_not_books` with drafted
  follow-ups (vendor chaser / client checklist item).
  """

  alias Nila.Formatters
  alias Nila.Fuzzy
  alias Nila.Gstin

  @ix "_ix"

  @doc """
  Whether this month has actually been reconciled against a GSTR-2B.

  Read from the recon's own content, never from whether an intake row exists.
  A month whose recon was written by any route — a seed, a backfill, an import
  that predates the current pipeline — still has real 2B-side content, and a
  page that asks the dumps table instead tells the truth about its plumbing
  while lying about the month: "nothing reconciles until the 2B is in", printed
  above six rows matched to the 2B.

  Only the buckets that require a 2B counterpart count. `in_books_not_2b`
  deliberately does not: those rows exist precisely because no 2B entry backed
  them, so a month of nothing but unmatched books bills has not seen a 2B.
  """
  def reconciled_against_2b?(recon) when is_map(recon) do
    Enum.any?(~w(matched value_mismatch in_2b_not_books needs_human), fn bucket ->
      recon |> Map.get(bucket) |> List.wrap() |> Enum.any?()
    end)
  end

  def reconciled_against_2b?(_recon), do: false

  @doc """
  Reconciles books invoices against GSTR-2B invoices.

  Options:

    * `:tolerance_paise` — max absolute drift, applied separately to taxable
      value and total tax (default `100`, i.e. ₹1);
    * `:date_window_days` — max date distance for corroboration (default `7`);
    * `:name_threshold` — min `Nila.Fuzzy` score for a vendor-name candidate
      (default `0.85`).

  Returns `%{"matched", "value_mismatch", "in_books_not_2b",
  "in_2b_not_books", "needs_human"}`. Matched/mismatch rows carry `"books"`,
  `"gstr2b"`, `"match_basis"`, and `"deltas"` (books minus 2B, paise). Other
  rows carry a `"reason"` (`%{"code", "message"}`) and a drafted
  `"next_action"`.
  """
  def reconcile(books_invoices, gstr2b_invoices, opts \\ []) do
    opts = opts(opts)

    g2b =
      gstr2b_invoices
      |> Enum.with_index()
      |> Enum.map(fn {g, i} -> Map.put(g, @ix, i) end)

    {gstin_books, no_gstin_books} =
      Enum.split_with(books_invoices, &Gstin.valid?(&1["vendor_gstin"]))

    acc = %{matched: [], value_mismatch: [], needs_human: []}

    {acc, gstin_books_left, g2b} =
      gstin_books
      |> Enum.group_by(& &1["vendor_gstin"])
      |> Enum.reduce({acc, [], g2b}, fn {gstin, group_books}, {acc, left, g2b} ->
        {group_g, other_g} = Enum.split_with(g2b, &(&1["vendor_gstin"] == gstin))
        {acc, books_left, g_left} = match_group(acc, group_books, group_g, opts)
        {acc, books_left ++ left, g_left ++ other_g}
      end)

    {acc, no_gstin_left, g2b} = fuzzy_name_rung(acc, no_gstin_books, g2b, opts)

    %{
      "matched" => Enum.reverse(acc.matched),
      "value_mismatch" => Enum.reverse(acc.value_mismatch),
      "needs_human" => Enum.reverse(acc.needs_human),
      "in_books_not_2b" => Enum.map(gstin_books_left ++ no_gstin_left, &books_residual/1),
      "in_2b_not_books" => Enum.map(g2b, &g2b_residual/1)
    }
  end

  defp opts(opts) do
    %{
      tolerance: Keyword.get(opts, :tolerance_paise, 100),
      date_window: Keyword.get(opts, :date_window_days, 7),
      name_threshold: Keyword.get(opts, :name_threshold, 0.85),
      candidate_floor: Keyword.get(opts, :candidate_floor_paise, 500),
      candidate_cap: Keyword.get(opts, :candidate_cap_paise, 2_500),
      candidate_pct_bp: Keyword.get(opts, :candidate_pct_bp, 10)
    }
  end

  @doc """
  Content ref for a GSTR-2B invoice, stable across re-reconciliation. A human
  resolution stores this so it keeps pointing at the same 2B candidate even
  after inputs are re-reconciled (the ephemeral position index is not stable).
  """
  def gstr2b_ref(g) do
    [g["vendor_gstin"], g["invoice_number"], g["taxable_paise"], g["total_paise"]]
    |> Enum.map_join("|", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Builds a `matched`/`value_mismatch` row for a human-confirmed pairing, using
  the same value logic as the machine rungs so a confirmed pair is byte-identical
  in shape to an auto-matched one. `basis` records that a human made the call.
  """
  def manual_pair(b, g, opts \\ []) do
    o = opts(opts)
    row = %{"books" => b, "gstr2b" => strip(g), "deltas" => deltas(b, g)}
    basis = ["human_confirmed"]

    if values_close?(b, g, o) do
      {"matched", Map.put(row, "match_basis", basis ++ ["value"])}
    else
      {"value_mismatch", Map.put(row, "match_basis", basis)}
    end
  end

  defp match_group(acc, books, g2b, opts) do
    {acc, books, g2b} = exact_inum_rung(acc, books, g2b, opts)
    {acc, books, g2b} = relaxed_inum_rung(acc, books, g2b, opts)
    inum_mismatch_rung(acc, books, g2b, opts)
  end

  defp exact_inum_rung(acc, books, g2b, opts) do
    g_by = Enum.group_by(g2b, &norm_inum(&1["invoice_number"]))

    {acc, books_left, used} =
      books
      |> Enum.group_by(&norm_inum(&1["invoice_number"]))
      |> Enum.reduce({acc, [], MapSet.new()}, fn {key, group_books}, {acc, left, used} ->
        case {group_books, if(key == "", do: [], else: Map.get(g_by, key, []))} do
          {_, []} ->
            {acc, group_books ++ left, used}

          {[b], [g]} ->
            {emit_pair(acc, b, g, ["gstin", "invoice_number"], opts), left, mark_used(used, [g])}

          {bs, gs} ->
            acc =
              Enum.reduce(bs, acc, fn b, acc ->
                push(
                  acc,
                  :needs_human,
                  needs_human_row(
                    b,
                    gs,
                    "ambiguous_matches",
                    "#{length(gs)} GSTR-2B invoice(s) and #{length(bs)} books invoice(s) share invoice number #{key}; confirm which pairing is correct."
                  )
                )
              end)

            {acc, left, mark_used(used, gs)}
        end
      end)

    {acc, books_left, reject_used(g2b, used)}
  end

  defp relaxed_inum_rung(acc, books, g2b, opts) do
    proposals =
      Enum.map(books, fn b ->
        case relax_inum(b["invoice_number"]) do
          "" -> {b, []}
          key -> {b, Enum.filter(g2b, &(relax_inum(&1["invoice_number"]) == key))}
        end
      end)

    resolve_proposals(acc, proposals, g2b, fn acc, b, g ->
      date_ok = dates_close?(b, g, opts)
      value_ok = values_close?(b, g, opts)

      cond do
        date_ok and value_ok ->
          {:consume, emit_pair(acc, b, g, ["gstin", "relaxed_invoice_number", "date"], opts)}

        date_ok or value_ok ->
          {:consume,
           push(
             acc,
             :needs_human,
             needs_human_row(
               b,
               [g],
               "relaxed_match_weak_corroboration",
               "Invoice numbers match after normalization but only one of date/value corroborates; confirm the pairing."
             )
           )}

        true ->
          :skip
      end
    end)
  end

  defp inum_mismatch_rung(acc, books, g2b, opts) do
    proposals =
      Enum.map(books, fn b ->
        {b, Enum.filter(g2b, &(dates_close?(b, &1, opts) and values_close?(b, &1, opts)))}
      end)

    resolve_proposals(acc, proposals, g2b, fn acc, b, g ->
      {:consume,
       push(
         acc,
         :needs_human,
         needs_human_row(
           b,
           [g],
           "invoice_number_mismatch",
           "Same vendor with matching value and date, but the invoice numbers disagree; confirm whether these are the same bill."
         )
       )}
    end)
  end

  defp fuzzy_name_rung(acc, books, g2b, opts) do
    proposals = Enum.map(books, fn b -> {b, fuzzy_candidates(b, g2b, opts)} end)

    resolve_proposals(acc, proposals, g2b, fn acc, b, g ->
      exact_inum = norm_inum(b["invoice_number"]) == norm_inum(g["invoice_number"])
      value_ok = values_close?(b, g, opts)

      if exact_inum and value_ok do
        {:consume, emit_pair(acc, b, g, ["fuzzy_vendor_name", "invoice_number"], opts)}
      else
        {:consume,
         push(
           acc,
           :needs_human,
           needs_human_row(
             b,
             [g],
             "fuzzy_name_weak_corroboration",
             "Vendor name matches approximately but the pairing lacks exact invoice number plus value corroboration; confirm the vendor and bill."
           )
         )}
      end
    end)
  end

  defp fuzzy_candidates(b, g2b, opts) do
    case Fuzzy.normalize(b["vendor_name"] || "") do
      "" ->
        []

      bname ->
        Enum.filter(g2b, fn g ->
          Fuzzy.match_score(bname, Fuzzy.normalize(g["vendor_name"] || "")) >=
            opts.name_threshold and
            (norm_inum(b["invoice_number"]) == norm_inum(g["invoice_number"]) or
               taxable_plausible?(b, g, opts))
        end)
    end
  end

  # Candidacy only — looser than `values_close?`, which gates matched/mismatch.
  # A value discrepancy must not erase identity evidence: two records that are
  # probably the same invoice should surface as a review candidate, with the
  # difference attached, rather than be declared unrelated. Handwritten cash
  # bills are hand-totaled, so the taxable ties to the portal while the tax
  # drifts a few rupees on rounding. Band = percentage of the value, floored to
  # absorb paise/rounding and capped so large invoices don't go loose.
  defp taxable_plausible?(b, g, opts) do
    bt = b["taxable_paise"] || 0
    gt = g["taxable_paise"] || 0
    abs(bt - gt) <= candidate_band(max(abs(bt), abs(gt)), opts)
  end

  defp candidate_band(value, opts) do
    min(opts.candidate_cap, max(opts.candidate_floor, div(value * opts.candidate_pct_bp, 10_000)))
  end

  defp resolve_proposals(acc, proposals, g2b, single_fun) do
    contested =
      proposals
      |> Enum.flat_map(fn {_b, cands} -> Enum.map(cands, & &1[@ix]) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_ix, n} -> n > 1 end)
      |> MapSet.new(fn {ix, _n} -> ix end)

    {acc, books_left, used} =
      Enum.reduce(proposals, {acc, [], MapSet.new()}, fn {b, cands}, {acc, left, used} ->
        cond do
          cands == [] ->
            {acc, [b | left], used}

          length(cands) > 1 or Enum.any?(cands, &MapSet.member?(contested, &1[@ix])) ->
            row =
              needs_human_row(
                b,
                cands,
                "ambiguous_matches",
                "This books invoice could pair with more than one GSTR-2B invoice at the same confidence level; confirm which pairing is correct."
              )

            {push(acc, :needs_human, row), left, mark_used(used, cands)}

          true ->
            [g] = cands

            case single_fun.(acc, b, g) do
              {:consume, acc} -> {acc, left, mark_used(used, [g])}
              :skip -> {acc, [b | left], used}
            end
        end
      end)

    {acc, books_left, reject_used(g2b, used)}
  end

  defp emit_pair(acc, b, g, basis, opts) do
    row = %{
      "books" => b,
      "gstr2b" => strip(g),
      "deltas" => deltas(b, g)
    }

    if values_close?(b, g, opts) do
      push(acc, :matched, Map.put(row, "match_basis", basis ++ ["value"]))
    else
      push(acc, :value_mismatch, Map.put(row, "match_basis", basis))
    end
  end

  defp deltas(b, g) do
    %{
      "taxable" => b["taxable_paise"] - g["taxable_paise"],
      "cgst" => tax(b, "cgst") - tax(g, "cgst"),
      "sgst" => tax(b, "sgst") - tax(g, "sgst"),
      "igst" => tax(b, "igst") - tax(g, "igst"),
      "total" => b["total_paise"] - g["total_paise"]
    }
  end

  defp values_close?(b, g, opts) do
    abs(b["taxable_paise"] - g["taxable_paise"]) <= opts.tolerance and
      abs(tax_sum(b) - tax_sum(g)) <= opts.tolerance
  end

  defp tax_sum(inv), do: tax(inv, "cgst") + tax(inv, "sgst") + tax(inv, "igst")

  defp tax(inv, key), do: get_in(inv, ["tax_paise", key]) || 0

  defp dates_close?(%{"invoice_date" => %Date{} = d1}, %{"invoice_date" => %Date{} = d2}, opts),
    do: abs(Date.diff(d1, d2)) <= opts.date_window

  defp dates_close?(_b, _g, _opts), do: false

  defp norm_inum(inum) do
    inum
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/^[^0-9A-Z]+|[^0-9A-Z]+$/, "")
  end

  defp relax_inum(inum) do
    s = norm_inum(inum)
    stripped = Regex.replace(~r|[-/ ]20\d{2}[-/]\d{2}$|, s, "")
    s = if stripped == "", do: s, else: stripped

    s
    |> String.replace(~r|[-/.: ]|, "")
    |> then(
      &Regex.replace(~r/\d+/, &1, fn run ->
        run |> String.to_integer() |> Integer.to_string()
      end)
    )
  end

  defp needs_human_row(b, candidates, code, message) do
    %{
      "books" => b,
      "candidates" => Enum.map(candidates, &strip/1),
      "reason" => %{"code" => code, "message" => message},
      "next_action" => "Review manually: " <> message
    }
  end

  @doc """
  The `in_books_not_2b` residual entry for a books invoice with no confident 2B
  match. Public so the workings overlay reuses the exact same shape when a human
  confirmation displaces a books row from an existing machine match.
  """
  def books_residual(b) do
    %{
      "books" => b,
      "reason" => %{
        "code" => "no_confident_gstr2b_match",
        "message" => "No confident GSTR-2B match was found automatically."
      },
      "next_action" =>
        "No GSTR-2B row matched invoice #{b["invoice_number"]} from #{b["vendor_name"]} automatically. Review the 2B for a near-match before concluding it is absent; if genuinely missing, ask the vendor to confirm it was reported in their GSTR-1."
    }
  end

  defp g2b_residual(g) do
    g = strip(g)

    %{
      "gstr2b" => g,
      "reason" => %{
        "code" => "missing_in_books",
        "message" => "No books invoice corresponds to this GSTR-2B invoice."
      },
      "next_action" =>
        "GSTR-2B shows invoice #{g["invoice_number"]} from vendor #{g["vendor_name"]} dated #{Formatters.format_display_date(g["invoice_date"])} for #{Formatters.format_money_with_paise(g["total_paise"])}; do you have this bill?"
    }
  end

  defp push(acc, bucket, row), do: Map.update!(acc, bucket, &[row | &1])

  defp mark_used(used, cands), do: Enum.reduce(cands, used, &MapSet.put(&2, &1[@ix]))

  defp reject_used(g2b, used), do: Enum.reject(g2b, &MapSet.member?(used, &1[@ix]))

  defp strip(g), do: Map.delete(g, @ix)
end
