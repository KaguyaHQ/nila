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

  alias Nila.Gst.InvoiceNumber
  alias Nila.Gst.Purchase.Books
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
    challenged = challenged_pairs(book_resolutions)

    Reconciliation.reconcile(books, g2b)
    |> apply_confirmations(confirmed)
    |> apply_rejections(rejected)
    |> apply_challenges(challenged)
    |> apply_acceptances(accepted_reasons(book_resolutions))
    |> apply_dismissals(dismissed_refs(ref_resolutions))
  end

  @doc "Replays source-month corrections without changing the stored source."
  def corrected_books(books, resolutions) do
    corrections =
      resolutions
      |> with_target("books_id")
      |> Replay.drop_reopened("books_id")
      |> Enum.filter(&(&1["verb"] == "correct_field"))

    apply_corrections(books, corrections)
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
        answer: attestation_answer(resolutions, [target, legacy_attestation_target(awaiting)]),
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
          do: document_key(row)

    for entry <- recon["in_2b_not_books"] || [],
        g = entry["gstr2b"] || entry,
        g["document_type"] != "credit_note",
        not MapSet.member?(accepted, document_key(g)),
        do: g
  end

  defp attestation_target(supplies), do: attestation_target(supplies, &InvoiceNumber.key/1)

  # The same digest under the weak normalization this module used before it
  # shared `InvoiceNumber`. Attestation targets are written into signed
  # resolutions, so recomputing them under the stronger key would orphan every
  # answer a reviewer has already given on a supply whose number carries
  # punctuation. New answers are written against the current target; this is
  # only ever read.
  defp legacy_attestation_target(supplies),
    do: attestation_target(supplies, &InvoiceNumber.legacy_key/1)

  defp attestation_target(supplies, normalize) do
    digest =
      supplies
      |> Enum.map(fn supply ->
        base = "#{supply["vendor_gstin"]}|#{normalize.(supply["invoice_number"])}"

        if supply["document_type"] in [nil, "invoice"],
          do: base,
          else: base <> "|#{supply["document_type"]}"
      end)
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "documents_held|#{digest}"
  end

  defp document_key(document) do
    type = document["document_type"] || "invoice"
    {type, document["vendor_gstin"], InvoiceNumber.key(document["invoice_number"])}
  end

  defp attestation_answer(resolutions, targets) do
    targets = List.wrap(targets)

    resolutions
    |> Enum.filter(fn r ->
      r["verb"] in ["attest_documents", "reopen"] and
        get_in(r, ["payload", "target"]) in targets
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
  # `Books.parse_date/1` tries ISO first and then the printed Indian formats,
  # so this accepts everything the old ISO-only reading did and additionally
  # the `15/04/2025` a reviewer types when retyping a date off the bill. That
  # used to stay a string, and `Reconciliation.dates_close?/3` matches on
  # `%Date{}` — so the corrected date silently stopped corroborating anything.
  defp coerce_date(%{"invoice_date" => date} = inv) when is_binary(date) do
    case Books.parse_date(date) do
      %Date{} = parsed -> Map.put(inv, "invoice_date", parsed)
      nil -> inv
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

  # A correction goes through the same normalization the extractor's output
  # does. It did not, and the asymmetry undid the correction: a reviewer
  # retyping a GSTIN the way it is printed — `33-AAACR5055K-1ZE` — stored the
  # separators verbatim, so `Gstin.valid?/1` failed, `invalid_gstin` fired
  # again on the value that had just been fixed, and `reconcile/3` dropped the
  # invoice out of the GSTIN ladder entirely into fuzzy-name matching. The
  # reviewer answered the question and the answer was thrown away.
  defp put_field(b, "invoice_number", value),
    do: Map.put(b, "invoice_number", InvoiceNumber.store(value))

  defp put_field(b, "invoice_date", value), do: coerce_date(Map.put(b, "invoice_date", value))

  defp put_field(b, "vendor_gstin", value) when is_binary(value) or is_nil(value) do
    {status, cleaned} = Books.clean_gstin(value)

    b
    |> Map.put("vendor_gstin", cleaned)
    |> Map.put("vendor_gstin_status", to_string(status))
  end

  defp put_field(b, "vendor_name", value), do: Map.put(b, "vendor_name", value)

  defp put_field(b, field, value)
       when field in ["taxable_paise", "total_paise"] and is_integer(value) and value >= 0,
       do: Map.put(b, field, value)

  defp put_field(b, "tax_paise", %{"cgst" => cgst, "sgst" => sgst, "igst" => igst} = value)
       when map_size(value) in [3, 4] and is_integer(cgst) and cgst >= 0 and is_integer(sgst) and
              sgst >= 0 and is_integer(igst) and igst >= 0,
       do:
         if(map_size(value) == 3 or (is_integer(value["cess"]) and value["cess"] >= 0),
           do: Map.put(b, "tax_paise", value),
           else: b
         )

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

  defp challenged_pairs(resolutions) do
    resolutions
    |> Replay.latest("books_id")
    |> Enum.reduce([], fn
      {_books_id, %{"verb" => "challenge_pair", "books_id" => books_id, "gstr2b_ref" => ref}},
      acc ->
        [{books_id, ref} | acc]

      _, acc ->
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

  # Rejecting an edge must also unwind an automatic match. The books and 2B
  # members then become separate components instead of silently remaining paired.
  defp apply_rejections(recon, rejected) do
    Enum.reduce(rejected, recon, fn {books_id, ref}, effective ->
      case paired_entry(effective, books_id, ref) do
        nil ->
          counterpart =
            effective["needs_human"]
            |> List.wrap()
            |> Enum.find_value(fn entry ->
              if get_in(entry, ["books", "id"]) == books_id do
                Enum.find(entry["candidates"] || [], &(Reconciliation.gstr2b_ref(&1) == ref))
              end
            end)

          effective =
            Map.update(effective, "needs_human", [], fn entries ->
              Enum.map(entries, fn entry ->
                if get_in(entry, ["books", "id"]) == books_id do
                  Map.update(entry, "candidates", [], fn candidates ->
                    Enum.reject(candidates, &(Reconciliation.gstr2b_ref(&1) == ref))
                  end)
                else
                  entry
                end
              end)
            end)

          still_candidate? =
            Enum.any?(effective["needs_human"] || [], fn entry ->
              Enum.any?(entry["candidates"] || [], &(Reconciliation.gstr2b_ref(&1) == ref))
            end)

          if counterpart && not still_candidate? do
            Map.update(
              effective,
              "in_2b_not_books",
              [%{"gstr2b" => counterpart}],
              &(&1 ++ [%{"gstr2b" => counterpart}])
            )
          else
            effective
          end

        entry ->
          effective
          |> drop_books(books_id)
          |> drop_gstr2b(ref)
          |> Map.update(
            "in_books_not_2b",
            [Reconciliation.books_residual(entry["books"])],
            &(&1 ++ [Reconciliation.books_residual(entry["books"])])
          )
          |> Map.update(
            "in_2b_not_books",
            [%{"gstr2b" => entry["gstr2b"]}],
            &(&1 ++ [%{"gstr2b" => entry["gstr2b"]}])
          )
      end
    end)
  end

  defp apply_challenges(recon, challenged) do
    Enum.reduce(challenged, recon, fn {books_id, ref}, effective ->
      case paired_entry(effective, books_id, ref) do
        nil ->
          effective

        entry ->
          question = %{
            "books" => entry["books"],
            "candidates" => [entry["gstr2b"]],
            "reason" => %{
              "code" => "challenged_automatic_match",
              "message" =>
                "A reviewer challenged Nila's automatic match. Confirm, reject, or correct it."
            },
            "next_action" => "Review the challenged match."
          }

          effective
          |> drop_books(books_id)
          |> drop_gstr2b(ref)
          |> Map.update("needs_human", [question], &(&1 ++ [question]))
      end
    end)
  end

  defp paired_entry(recon, books_id, ref) do
    Enum.find_value(["matched", "value_mismatch"], fn bucket ->
      Enum.find(recon[bucket] || [], fn entry ->
        get_in(entry, ["books", "id"]) == books_id and
          Reconciliation.gstr2b_ref(entry["gstr2b"]) == ref
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
