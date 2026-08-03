defmodule Nila.Gst.Purchase.Workings do
  @moduledoc """
  Layers human resolutions over the engine's pristine `recon` to produce the
  *effective* reconciliation the register and pack render from.

  The engine's `recon` is machine truth and is never mutated. A resolution is
  an authoritative edge on top of it:

    * `correct_field` rewrites a books field, then the affected records are
      re-reconciled by the real `Reconciliation.reconcile/3` (never a reimplementation);
    * `confirm_pair` pins a books row and a 2B row as `matched`/`value_mismatch`
      using `Reconciliation.manual_pair/3`;
    * `reject_pair` forbids a pairing so the engine never re-suggests it;
    * `accept_unmatched` keeps a decided books row honestly outside 2B;
    * `dismiss_2b` removes a 2B-only row confirmed as not belonging to the client.

  Pure: recon + resolutions in, effective recon out. Latest resolution per
  target wins (append-only store, so ordering is by insertion).

  `materialize/3` returns the effective recon; `Register.rows/summary` then
  build the projection, so every surface reads one source and cannot drift.
  """

  alias Nila.Gst.Purchase.Reconciliation
  alias Nila.Gst.Replay

  @books_buckets ["matched", "value_mismatch", "needs_human", "in_books_not_2b"]

  @doc """
  Applies resolutions (append-only, oldest first) to `recon`, returning the
  effective recon. `resolutions` are plain maps with string keys mirroring the
  `Nila.Gst.Purchase.Resolution` schema (`"verb"`, `"books_id"`, `"gstr2b_ref"`,
  `"payload"`).
  """
  def materialize(recon, resolutions, _opts \\ []) do
    books = recon |> books_invoices() |> Enum.map(&coerce_date/1)
    g2b = recon |> gstr2b_invoices() |> Enum.map(&coerce_date/1)

    book_resolutions =
      resolutions
      |> with_target("books_id")
      |> Replay.drop_reopened("books_id")

    ref_resolutions =
      resolutions
      |> with_target("gstr2b_ref")
      |> Replay.drop_reopened("gstr2b_ref")

    {corrections, pairs} =
      Enum.split_with(book_resolutions, &(&1["verb"] == "correct_field"))

    books = apply_corrections(books, corrections)
    {confirmed, rejected} = fold_pairs(pairs)

    Reconciliation.reconcile(books, g2b)
    |> apply_confirmations(confirmed)
    |> apply_rejections(rejected)
    |> apply_acceptances(accepted_reasons(book_resolutions))
    |> apply_dismissals(dismissed_refs(ref_resolutions))
  end

  @doc """
  The effective latest decision per books row: `%{books_id => verb}` after undo
  (`reopen`) cancellation. A books row absent from the map is still open.
  """
  def decisions(resolutions) do
    resolutions
    |> with_target("books_id")
    |> Replay.decisions("books_id")
  end

  @doc "The accepted-unmatched reason per effective books-row decision."
  def accepted_reasons(resolutions) do
    resolutions
    |> with_target("books_id")
    |> Replay.latest("books_id")
    |> Enum.reduce(%{}, fn
      {books_id, %{"verb" => "accept_unmatched", "payload" => %{"reason" => reason}}}, acc ->
        Map.put(acc, books_id, reason)

      _decision, acc ->
        acc
    end)
  end

  @doc "The effective latest decision per stable GSTR-2B content reference."
  def gstr2b_decisions(resolutions) do
    resolutions
    |> with_target("gstr2b_ref")
    |> Replay.decisions("gstr2b_ref")
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

  @doc """
  The s.16(2)(a) attestation for the 2B supplies with no bill on file.

  Returns `%{target, answer, count, tax_paise}`, or `nil` when nothing is
  awaiting a document — there is no question to ask.

  The target is scoped by the supply set it was asked about, so a later 2B
  import that adds an unsubstantiated supply reopens the question rather than
  inheriting an answer given about a different set. Same mechanism as the sales
  cess question, for the same reason.
  """
  def document_attestation(recon, rows, resolutions) do
    awaiting = awaiting_supplies(recon, rows)

    if awaiting != [] do
      target = attestation_target(awaiting)

      %{
        target: target,
        answer: attestation_answer(resolutions, target),
        count: length(awaiting),
        tax_paise: awaiting |> Enum.map(&supply_tax/1) |> Enum.sum()
      }
    end
  end

  @doc "Whether the attestation is answered in a way that permits a signature."
  def documents_attested?(nil), do: true
  def documents_attested?(%{answer: answer}), do: answer in ~w(held not_held)

  defp awaiting_supplies(recon, rows) do
    accepted =
      for row <- rows,
          row["bucket"] == "in_2b_not_books",
          row["accepted_reason"] != nil,
          into: MapSet.new(),
          do: {row["vendor_gstin"], norm_inum(row["invoice_number"])}

    for entry <- recon["in_2b_not_books"] || [],
        g = entry["gstr2b"] || entry,
        not MapSet.member?(accepted, {g["vendor_gstin"], norm_inum(g["invoice_number"])}),
        do: g
  end

  defp attestation_target(supplies) do
    digest =
      supplies
      |> Enum.map(&"#{&1["vendor_gstin"]}|#{norm_inum(&1["invoice_number"])}")
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "documents_held|#{digest}"
  end

  defp attestation_answer(resolutions, target) do
    resolutions
    |> Enum.filter(fn r ->
      r["verb"] in ["attest_documents", "reopen"] and
        get_in(r, ["payload", "target"]) == target
    end)
    |> List.last()
    |> case do
      %{"verb" => "attest_documents", "payload" => %{"answer" => answer}}
      when answer in ~w(held not_held unknown) ->
        answer

      _none_or_reopened ->
        nil
    end
  end

  defp supply_tax(supply), do: (supply["tax_paise"] || %{}) |> Map.values() |> Enum.sum()

  defp norm_inum(inum), do: inum |> to_string() |> String.trim() |> String.upcase()

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
    |> Enum.uniq_by(&Reconciliation.gstr2b_ref/1)
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

  defp with_target(resolutions, key), do: Enum.filter(resolutions, &(&1[key] != nil))

  defp dismissed_refs(resolutions) do
    resolutions
    |> Replay.latest("gstr2b_ref")
    |> Enum.reduce(MapSet.new(), fn
      {ref, %{"verb" => "dismiss_2b"}}, refs -> MapSet.put(refs, ref)
      _decision, refs -> refs
    end)
  end

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
    g = Enum.find(gstr2b_invoices(recon), &(Reconciliation.gstr2b_ref(&1) == ref))

    if b && g do
      {bucket, row} = Reconciliation.manual_pair(b, g)

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
      Enum.reject(entries, &(Reconciliation.gstr2b_ref(&1["gstr2b"] || &1) == ref))
    end)
    |> Map.update("needs_human", [], fn entries ->
      Enum.map(entries, fn e ->
        Map.update(e, "candidates", [], fn cands ->
          Enum.reject(cands, &(Reconciliation.gstr2b_ref(&1) == ref))
        end)
      end)
    end)
  end

  defp unwind_match(recon, bucket, ref) do
    {displaced, kept} =
      Enum.split_with(recon[bucket] || [], &(Reconciliation.gstr2b_ref(&1["gstr2b"]) == ref))

    residuals = Enum.map(displaced, &Reconciliation.books_residual(&1["books"]))

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
          Enum.reject(cands, &MapSet.member?(rejected, {bid, Reconciliation.gstr2b_ref(&1)}))
        end)
      end)
    end)
  end

  defp apply_acceptances(recon, accepted) do
    Enum.reduce(accepted, recon, fn {books_id, reason}, effective ->
      case Enum.find(books_invoices(effective), &(&1["id"] == books_id)) do
        nil ->
          effective

        books ->
          residual =
            books
            |> Reconciliation.books_residual()
            |> Map.put("accepted_reason", reason)
            |> Map.put("next_action", accepted_next_action(reason))

          effective
          |> drop_books(books_id)
          |> Map.update("in_books_not_2b", [residual], &(&1 ++ [residual]))
      end
    end)
  end

  defp accepted_next_action("await_2b"),
    do: "Keep the bill outside this month's ITC and check a future GSTR-2B."

  defp accepted_next_action("not_claimable"), do: "Do not claim this bill this month."
  defp accepted_next_action(_reason), do: nil

  defp apply_dismissals(recon, dismissed_refs) do
    Map.update(recon, "in_2b_not_books", [], fn entries ->
      Enum.reject(entries, fn entry ->
        entry
        |> then(&(&1["gstr2b"] || &1))
        |> Reconciliation.gstr2b_ref()
        |> then(&MapSet.member?(dismissed_refs, &1))
      end)
    end)
  end
end
