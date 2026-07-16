defmodule Nila.Gst.Workings do
  @moduledoc """
  Layers human resolutions over the engine's pristine `recon` to produce the
  *effective* reconciliation the register and pack render from.

  The engine's `recon` is machine truth and is never mutated. A resolution is
  an authoritative edge on top of it:

    * `correct_field` rewrites a books field, then the affected records are
      re-reconciled by the real `Recon.reconcile/3` (never a reimplementation);
    * `confirm_pair` pins a books row and a 2B row as `matched`/`value_mismatch`
      using `Recon.manual_pair/3`;
    * `reject_pair` forbids a pairing so the engine never re-suggests it.

  Pure: recon + resolutions in, effective recon out. Latest resolution per
  target wins (append-only store, so ordering is by insertion).

  `materialize/3` returns the effective recon; `Register.rows/summary` then
  build the projection, so every surface reads one source and cannot drift.
  """

  alias Nila.Gst.Recon

  @books_buckets ["matched", "value_mismatch", "needs_human", "in_books_not_2b"]

  @doc """
  Applies resolutions (append-only, oldest first) to `recon`, returning the
  effective recon. `resolutions` are plain maps with string keys mirroring the
  `Nila.Gst.Resolution` schema (`"verb"`, `"books_id"`, `"gstr2b_ref"`,
  `"payload"`).
  """
  def materialize(recon, resolutions, _opts \\ []) do
    books = recon |> books_invoices() |> Enum.map(&coerce_date/1)
    g2b = recon |> gstr2b_invoices() |> Enum.map(&coerce_date/1)

    resolutions = drop_reopened(resolutions)

    {corrections, pairs} =
      Enum.split_with(resolutions, &(&1["verb"] == "correct_field"))

    books = apply_corrections(books, corrections)
    {confirmed, rejected} = fold_pairs(pairs)

    recon = Recon.reconcile(books, g2b)
    recon = apply_confirmations(recon, confirmed)
    apply_rejections(recon, rejected)
  end

  # `reopen` is undo: for each books row it discards every prior decision on that
  # row, returning it to the engine's default. Append-only and latest-wins — a
  # later confirm/reject after a reopen simply lands on the clean slate. Drops
  # each books_id's events that precede its last reopen, then the reopens.
  defp drop_reopened(resolutions) do
    last_reopen =
      resolutions
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {r, i}, acc ->
        if r["verb"] == "reopen", do: Map.put(acc, r["books_id"], i), else: acc
      end)

    resolutions
    |> Enum.with_index()
    |> Enum.reject(fn {r, i} ->
      r["verb"] == "reopen" or i < Map.get(last_reopen, r["books_id"], -1)
    end)
    |> Enum.map(fn {r, _i} -> r end)
  end

  @doc """
  The effective latest decision per books row: `%{books_id => verb}` after undo
  (`reopen`) cancellation. A books row absent from the map is still open.
  """
  def decisions(resolutions) do
    resolutions
    |> drop_reopened()
    |> Enum.reduce(%{}, fn r, acc -> Map.put(acc, r["books_id"], r["verb"]) end)
  end

  @doc """
  The effective block/allow decision per ITC block target: `%{block_id => verb}`
  where verb is `"block_itc" | "allow_itc"`, latest wins. These target a
  `payload["block_id"]`, independent of the recon buckets. `reopen` on a block
  target clears it back to Nila's recommendation.
  """
  def itc_decisions(resolutions) do
    resolutions
    |> Enum.filter(&(&1["verb"] in ["block_itc", "allow_itc", "reopen"]))
    |> Enum.reduce(%{}, fn r, acc ->
      case {r["verb"], get_in(r, ["payload", "block_id"])} do
        {_verb, nil} -> acc
        {"reopen", id} -> Map.delete(acc, id)
        {verb, id} -> Map.put(acc, id, verb)
      end
    end)
  end

  @doc "The books invoices embedded in a recon, one per books-side bucket entry."
  def books_invoices(recon) do
    for bucket <- @books_buckets,
        entry <- recon[bucket] || [],
        books = entry["books"],
        books != nil,
        do: books
  end

  @doc """
  The GSTR-2B invoices embedded in a recon, deduped by content ref. Rebuilt by
  union across matched/value_mismatch (`gstr2b`), needs_human (`candidates`),
  and in_2b_not_books residuals.
  """
  def gstr2b_invoices(recon) do
    matched = for b <- ["matched", "value_mismatch"], e <- recon[b] || [], g = e["gstr2b"], do: g
    cands = for e <- recon["needs_human"] || [], g <- e["candidates"] || [], do: g
    residual = for e <- recon["in_2b_not_books"] || [], g = e["gstr2b"] || e, do: g

    (matched ++ cands ++ residual)
    |> Enum.uniq_by(&Recon.gstr2b_ref/1)
  end

  # Stored recon is JSON: dates are ISO strings. The reconciler's date
  # corroboration needs %Date{}, so coerce on the way back in. A correction may
  # also set invoice_date, handled the same way in put_field/3.
  defp coerce_date(%{"invoice_date" => date} = inv) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> Map.put(inv, "invoice_date", d)
      {:error, _} -> inv
    end
  end

  defp coerce_date(inv), do: inv

  defp apply_corrections(books, corrections) do
    by_id =
      corrections
      |> Enum.group_by(& &1["books_id"])
      |> Map.new(fn {id, cs} -> {id, latest_field_values(cs)} end)

    Enum.map(books, fn b ->
      case Map.get(by_id, b["id"]) do
        nil ->
          b

        fields ->
          Enum.reduce(fields, b, fn {field, value}, acc -> put_field(acc, field, value) end)
      end
    end)
  end

  # Latest correction per field wins.
  defp latest_field_values(corrections) do
    corrections
    |> Enum.reduce(%{}, fn c, acc ->
      Map.put(acc, c["payload"]["field"], c["payload"]["to"])
    end)
  end

  defp put_field(b, "invoice_number", value), do: Map.put(b, "invoice_number", value)
  defp put_field(b, "invoice_date", value), do: coerce_date(Map.put(b, "invoice_date", value))
  defp put_field(b, "vendor_gstin", value), do: Map.put(b, "vendor_gstin", value)
  defp put_field(b, "vendor_name", value), do: Map.put(b, "vendor_name", value)
  defp put_field(b, _field, _value), do: b

  # Folds confirm/reject events in insertion order so the latest decision per
  # pair wins: a confirm pins books_id -> ref and un-rejects that pair; a reject
  # marks the pair and clears a matching confirm. Returns the confirmed map
  # (books_id -> ref) and the rejected set of {books_id, ref}.
  defp fold_pairs(pairs) do
    Enum.reduce(pairs, {%{}, MapSet.new()}, fn
      %{"verb" => "confirm_pair", "books_id" => bid, "gstr2b_ref" => ref},
      {confirmed, rejected} ->
        {Map.put(confirmed, bid, ref), MapSet.delete(rejected, {bid, ref})}

      %{"verb" => "reject_pair", "books_id" => bid, "gstr2b_ref" => ref}, {confirmed, rejected} ->
        confirmed = if confirmed[bid] == ref, do: Map.delete(confirmed, bid), else: confirmed
        {confirmed, MapSet.put(rejected, {bid, ref})}

      _other, acc ->
        acc
    end)
  end

  # Confirmed pairs: pull the books row and its 2B candidate out of whatever
  # bucket they landed in and emit a manual match.
  defp apply_confirmations(recon, confirmed) do
    Enum.reduce(confirmed, recon, fn {books_id, ref}, recon ->
      confirm_one(recon, books_id, ref)
    end)
  end

  defp confirm_one(recon, books_id, ref) do
    b = Enum.find(books_invoices(recon), &(&1["id"] == books_id))
    g = Enum.find(gstr2b_invoices(recon), &(Recon.gstr2b_ref(&1) == ref))

    if b && g do
      {bucket, row} = Recon.manual_pair(b, g)

      recon
      |> drop_books(books_id)
      |> drop_gstr2b(ref)
      |> Map.update(bucket, [row], &(&1 ++ [row]))
    else
      recon
    end
  end

  # Drop every trace of a books invoice from all buckets it might sit in.
  defp drop_books(recon, books_id) do
    recon
    |> Map.new(fn
      {bucket, entries} when bucket in @books_buckets ->
        {bucket, Enum.reject(entries, &(get_in(&1, ["books", "id"]) == books_id))}

      pair ->
        pair
    end)
  end

  # Remove every trace of a 2B invoice (by content ref) so a confirmed pairing
  # can't double-count it: drop it from the residual bucket and from any
  # needs_human candidate list, AND unwind any existing machine match that used
  # it — the books row it was matched to falls back to `in_books_not_2b` so it
  # isn't silently orphaned (it re-enters review, correctly, having lost its 2B).
  defp drop_gstr2b(recon, ref) do
    recon
    |> unwind_match("matched", ref)
    |> unwind_match("value_mismatch", ref)
    |> Map.update("in_2b_not_books", [], fn entries ->
      Enum.reject(entries, &(Recon.gstr2b_ref(&1["gstr2b"] || &1) == ref))
    end)
    |> Map.update("needs_human", [], fn entries ->
      Enum.map(entries, fn e ->
        Map.update(e, "candidates", [], fn cands ->
          Enum.reject(cands, &(Recon.gstr2b_ref(&1) == ref))
        end)
      end)
    end)
  end

  defp unwind_match(recon, bucket, ref) do
    {displaced, kept} =
      Enum.split_with(recon[bucket] || [], &(Recon.gstr2b_ref(&1["gstr2b"]) == ref))

    residuals = Enum.map(displaced, &Recon.books_residual(&1["books"]))

    recon
    |> Map.put(bucket, kept)
    |> Map.update("in_books_not_2b", residuals, &(&1 ++ residuals))
  end

  # A rejected pair drops that 2B candidate from the books row's needs_human
  # entry. If that empties the candidate list, the row stays in needs_human as
  # an unmatched review (its books data and reason are intact).
  defp apply_rejections(recon, rejected) do
    Map.update(recon, "needs_human", [], fn entries ->
      Enum.map(entries, fn e ->
        bid = get_in(e, ["books", "id"])

        Map.update(e, "candidates", [], fn cands ->
          Enum.reject(cands, &MapSet.member?(rejected, {bid, Recon.gstr2b_ref(&1)}))
        end)
      end)
    end)
  end
end
