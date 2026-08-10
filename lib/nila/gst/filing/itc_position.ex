defmodule Nila.Gst.Filing.ItcPosition do
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
      `ceiling_paise` is invoice and debit-note tax across all GSTR-2B rows the
      engine saw, which ties to filed 3B Table 4A. Supplier credit notes remain
      positive-valued evidence and reverse ITC in Table 4B(2).
    * Blocked credits reduce what is *claimable* below the ceiling:
      - `personal_expense_17_5` / `gstin_state_mismatch`: the row's full tax is
        ineligible (s.17(5) / inter-state CGST-SGST wrongly charged).
      - `duplicate_invoice`: only the *extra* copies are ineligible — one copy
        is a real bill. A group of N identical scans blocks (N-1) copies' tax.
  """

  alias Nila.Gst.InvoiceNumber

  @full_block ~w(personal_expense_17_5 gstin_state_mismatch)
  @zero_heads %{"igst" => 0, "cgst" => 0, "sgst" => 0}

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
          "tax_paise", "tax_heads" => %{"igst"|"cgst"|"sgst" => paise},
          "reason", "state" => "recommended"|"blocked"|"allowed"
        }]
      }
  """
  def compute(recon, rows, decisions \\ %{}) do
    ceiling = ceiling_paise(recon)
    blocks = Enum.map(block_candidates(rows), &decide(&1, decisions))
    recommended = blocks |> Enum.reject(&(&1["state"] == "allowed")) |> sum_tax()

    # Only blocks that sit on 2B-backed credit can reduce the ceiling. A books
    # bill the portal never reported contributes nothing to `ceiling_paise`, so
    # subtracting its block took the month negative: blocking an ₹180 personal
    # expense on a books-only row produced a claimable ITC of −₹180. It was
    # never claimable; there is nothing to withhold.
    blocked_in_ceiling =
      blocks
      |> Enum.filter(&(&1["state"] == "blocked" and &1["in_ceiling"]))
      |> sum_tax()

    blocked = blocks |> Enum.filter(&(&1["state"] == "blocked")) |> sum_tax()
    partition = partition(recon, rows, blocked_in_ceiling)

    Map.merge(partition, %{
      "ceiling_paise" => ceiling,
      "recommended_paise" => recommended,
      "blocked_paise" => blocked,
      "blocked_outside_ceiling_paise" => blocked - blocked_in_ceiling,
      "blocks" => blocks
    })
  end

  @doc """
  The 2B ceiling split into terminal financial states, and the claim split by
  whether the document backing it is in hand.

      reported_2b = claimable + pending_decision + blocked
      claimable   = substantiated + awaiting_document

  Substantiation is deliberately *not* a fourth state beside `claimable`. Under
  s.16(2) the conditions are cumulative — (a) possession of the tax invoice and
  (aa) the supply appearing in the 2B — so a supply the registered person holds
  no invoice for is genuinely not claimable. But possession is the *client's*,
  not Nila's document pile: `awaiting_bill?/1` means the bill has not reached
  *us*, which says nothing about whether the client holds it, and in the common
  case they do and simply have not forwarded it. Withholding on that signal
  would swing the filed number on Nila's collection state rather than on the
  client's legal position. So the money stays in the claim, named, and is
  attested rather than assumed.

  Where a row could sit in two states, precedence is
  `blocked` > `pending_decision` > `awaiting_document`, on terminality then
  actionability: s.17(5) ineligibility is the only one no decision and no
  document can move, so it absorbs; and between the other two a reviewer can act
  on a decision today, so ordering it second would bury an answerable row in a
  queue nobody can work.
  """
  def partition(recon, rows, blocked_in_ceiling) do
    reported = ceiling_paise(recon)
    credit_note_reversal = credit_note_reversal_paise(recon)
    reversal_applied = min(credit_note_reversal, reported)
    after_reversal = reported - reversal_applied
    raw_pending = pending_decision_paise(recon, rows)
    raw_awaiting = awaiting_document_paise(recon, rows)
    raw_awaiting_heads = awaiting_document_heads(recon, rows)

    # A block can only withhold credit the ceiling actually contains. `rows` and
    # `recon` are two projections of the same month and a row can claim a bucket
    # its 2B entry does not back — a stale snapshot, a row rebuilt after recon
    # moved on. Clamping keeps the equation an identity instead of letting the
    # two drift into an impossible figure.
    #
    # But a clamp that fires silently turns a data inconsistency into a clean
    # split nobody can question, so each one is reported. A figure that had to
    # be clamped is a bug upstream, not a number to trust.
    pending = min(raw_pending, after_reversal)
    blocked = blocked_in_ceiling |> min(after_reversal - pending) |> max(0)
    claimable = after_reversal - blocked - pending

    # Substantiation splits the claim, so it cannot exceed it: every rupee
    # awaiting a document is by definition inside the claim.
    awaiting = min(raw_awaiting, claimable)

    report_clamps(reported, %{
      credit_note_reversal: {credit_note_reversal, reversal_applied},
      pending: {raw_pending, pending},
      blocked: {blocked_in_ceiling, blocked},
      awaiting: {raw_awaiting, awaiting}
    })

    %{
      "reported_2b_paise" => reported,
      "credit_note_reversal_paise" => credit_note_reversal,
      "credit_note_reversal_applied_paise" => reversal_applied,
      "credit_note_reversal_excess_paise" => credit_note_reversal - reversal_applied,
      "claimable_paise" => claimable,
      "pending_decision_paise" => pending,
      "blocked_in_ceiling_paise" => blocked,
      "awaiting_document_paise" => awaiting,
      "awaiting_document_heads" => allocate(raw_awaiting_heads, awaiting),
      "substantiated_paise" => claimable - awaiting
    }
  end

  @doc """
  Splits a head-wise figure so it sums to `target` exactly.

  Normally `target` already equals the head sum and this is the identity; it
  only does work in the clamped case, where the lump was cut to keep the
  partition an identity and the heads have to follow it or Table 4 stops tying
  to the bridge.
  """
  def allocate(heads, target)

  def allocate(heads, target) do
    heads = Map.merge(@zero_heads, heads || %{})
    total = heads |> Map.values() |> Enum.sum()

    cond do
      total == target ->
        heads

      total <= 0 ->
        @zero_heads

      true ->
        scaled = Map.new(heads, fn {h, v} -> {h, div(v * target, total)} end)
        {largest, _} = Enum.max_by(heads, fn {_h, v} -> v end)
        Map.update!(scaled, largest, &(&1 + (target - Enum.sum(Map.values(scaled)))))
    end
  end

  @doc "Emitted whenever a partition term had to be clamped to keep the identity."
  def clamp_event, do: [:nila, :gst, :itc, :partition_clamped]

  defp report_clamps(reported, terms) do
    for {term, {raw, clamped}} <- terms, raw != clamped do
      :telemetry.execute(
        clamp_event(),
        %{raw_paise: raw, clamped_paise: clamped, difference_paise: raw - clamped},
        %{term: term, reported_2b_paise: reported}
      )
    end
  end

  # 2B-backed money whose bucket still needs a human: an ambiguous match, or a
  # 2B row routed to review. Excludes value mismatches — the return takes the 2B
  # figure either way, so no answer moves the money — and excludes anything
  # already blocked, which owns its rupees outright.
  defp pending_decision_paise(recon, rows) do
    blocked_keys = blocked_row_keys(rows)

    recon
    |> awaiting_2b_invoices()
    |> Enum.filter(&available_document?/1)
    |> Enum.reject(&MapSet.member?(blocked_keys, invoice_key(&1)))
    |> Enum.map(&tax_sum/1)
    |> Enum.sum()
  end

  # 2B rows the books have no document for. A 2B-only row carries no flags by
  # construction (`register.ex` `g2b_only_rows/1`), so it cannot also be
  # blocked; and it is not pending, because no judgement here can produce a bill
  # nobody sent.
  defp awaiting_document_paise(recon, rows) do
    accepted = accepted_2b_only_keys(rows)

    for entry <- recon["in_2b_not_books"] || [],
        g = entry["gstr2b"] || entry,
        available_document?(g),
        not MapSet.member?(accepted, invoice_key(g)),
        reduce: 0 do
      total -> total + tax_sum(g)
    end
  end

  # Same traversal as `awaiting_document_paise/2`, head-wise. Table 4 is
  # head-wise, so withholding this money from the return needs the split; the
  # two must stay in step or 4B reverses a different figure than the bridge
  # says was withheld.
  defp awaiting_document_heads(recon, rows) do
    accepted = accepted_2b_only_keys(rows)

    heads =
      for entry <- recon["in_2b_not_books"] || [],
          g = entry["gstr2b"] || entry,
          available_document?(g),
          not MapSet.member?(accepted, invoice_key(g)),
          do: g["tax_paise"] || %{}

    sum_heads(heads)
  end

  defp blocked_row_keys(rows) do
    for row <- rows,
        row["flags"] not in [nil, []],
        Enum.any?(row["flags"], &(&1["code"] in @full_block)),
        into: MapSet.new(),
        do: invoice_key(row)
  end

  defp accepted_2b_only_keys(rows) do
    for row <- rows,
        row["bucket"] == "in_2b_not_books",
        row["accepted_reason"] != nil,
        into: MapSet.new(),
        do: invoice_key(row)
  end

  defp invoice_key(row),
    do: {document_type(row), row["vendor_gstin"], norm(row["invoice_number"])}

  @doc """
  Applies the s.16(2)(a) attestation to a computed position.

  The unsubstantiated money stays in the claim by default — `awaiting_bill?/1`
  says the bill has not reached Nila, not that the client lacks it. Only an
  explicit *not held* moves it out, and it leaves as its own term rather than
  being folded into `blocked`: it is a substantiation failure, not an
  ineligible credit, and a reviewer reading the bridge should see which.

  On the *return* the two converge: `unsubstantiated_withheld_heads` reverses in
  4B(2) alongside the blocks (`Gstr3b.assemble/3`). 4A(5) is auto-populated from
  the 2B on the portal, so withholding by shrinking it would break the tie-out
  this engine is built to pass; 4C lands identically either way. Hence the head
  split — the lump alone cannot fill a head-wise table.

  `unknown` withholds the signature (`Workings.documents_attested?/1`) but does
  not move the money — nobody has said the credit is bad, only that nobody has
  checked.
  """
  def apply_attestation(position, attestation)
  # `attestation_required` exists because `documents_attested` cannot carry the
  # difference between "no supply needs attesting" and "a supply does and nobody
  # has answered" — both were `nil`. A surface reading only the answer offered
  # the 3B signature on the second case, where the server refuses it.
  def apply_attestation(position, nil) do
    position
    |> Map.put("documents_attested", nil)
    |> Map.put("attestation_required", false)
  end

  def apply_attestation(position, %{answer: "not_held"} = attestation) do
    withheld = min(position["awaiting_document_paise"], position["claimable_paise"])

    position
    |> Map.merge(%{
      "claimable_paise" => position["claimable_paise"] - withheld,
      "awaiting_document_paise" => 0,
      "unsubstantiated_withheld_paise" => withheld,
      "unsubstantiated_withheld_heads" => allocate(position["awaiting_document_heads"], withheld),
      "documents_attested" => "not_held",
      "attestation_required" => true
    })
    |> Map.put("attestation_target", attestation.target)
  end

  def apply_attestation(position, attestation) do
    position
    |> Map.put("documents_attested", attestation.answer)
    |> Map.put("attestation_required", true)
    |> Map.put("attestation_target", attestation.target)
  end

  def apply_document_cases(position, case_lines) do
    cases =
      Enum.filter(
        case_lines,
        &(&1.current_gstr2b? and not &1.has_books? and &1.document_type != "credit_note")
      )

    withheld_cases = Enum.filter(cases, &(&1.document_state == "not_held"))
    withheld_heads = withheld_cases |> Enum.map(& &1.tax_heads) |> sum_heads()
    raw_withheld = withheld_heads |> Map.values() |> Enum.sum()
    withheld = min(raw_withheld, position["claimable_paise"])
    settled? = Enum.all?(cases, &(&1.document_state in ~w(held not_held)))

    position
    |> Map.merge(%{
      "claimable_paise" => position["claimable_paise"] - withheld,
      "awaiting_document_paise" => max(position["awaiting_document_paise"] - withheld, 0),
      "unsubstantiated_withheld_paise" => withheld,
      "unsubstantiated_withheld_heads" => allocate(withheld_heads, withheld),
      "documents_attested" => if(settled?, do: "per_case", else: nil),
      "attestation_required" => cases != []
    })
  end

  @doc "The stable id a block/allow resolution targets for one flagged row."
  def block_id(row_id, code), do: "#{row_id}:#{code}"

  # The 2B ITC ceiling — every invoice and debit note the engine saw, whichever
  # bucket recon put it in. Credit notes are a separate Table 4B(2) reversal.
  def ceiling_paise(recon) do
    recon
    |> gstr2b_documents()
    |> Enum.filter(&available_document?/1)
    |> Enum.map(&tax_sum/1)
    |> Enum.sum()
  end

  @doc """
  The ceiling split by tax head (`%{"igst" | "cgst" | "sgst" => paise}`) —
  same traversal as `ceiling_paise/1`, so the heads always sum to it. 3B's
  Table 4 is head-wise; the lump total alone cannot fill it.
  """
  def ceiling_heads(recon) do
    recon
    |> gstr2b_documents()
    |> Enum.filter(&available_document?/1)
    |> Enum.map(&(&1["tax_paise"] || %{}))
    |> sum_heads()
  end

  @doc "Positive-valued supplier credit-note tax that reverses in Table 4B(2)."
  def credit_note_reversal_paise(recon) do
    recon |> credit_note_documents() |> Enum.map(&tax_sum/1) |> Enum.sum()
  end

  @doc "Head-wise supplier credit-note reversal for Table 4B(2)."
  def credit_note_reversal_heads(recon) do
    recon
    |> credit_note_documents()
    |> Enum.map(&(&1["tax_paise"] || %{}))
    |> sum_heads()
  end

  @doc "Sums a list of head maps (`%{\"igst\" | \"cgst\" | \"sgst\" => paise}`)."
  def sum_heads(head_maps) do
    Enum.reduce(head_maps, %{"igst" => 0, "cgst" => 0, "sgst" => 0}, fn heads, acc ->
      Map.new(acc, fn {k, v} -> {k, v + (heads[k] || 0)} end)
    end)
  end

  defp gstr2b_documents(recon) do
    matched =
      for bucket <- ["matched", "value_mismatch"],
          entry <- recon[bucket] || [],
          gstr2b = entry["gstr2b"],
          do: gstr2b

    residual =
      for entry <- recon["in_2b_not_books"] || [], do: entry["gstr2b"] || entry

    (matched ++ residual ++ awaiting_2b_invoices(recon))
    |> Enum.uniq_by(&document_ref/1)
  end

  defp credit_note_documents(recon) do
    portal = Enum.filter(gstr2b_documents(recon), &(document_type(&1) == "credit_note"))
    portal_keys = MapSet.new(portal, &invoice_key/1)

    books_only =
      for entry <- recon["in_books_not_2b"] || [],
          books = entry["books"],
          document_type(books) == "credit_note",
          not MapSet.member?(portal_keys, invoice_key(books)),
          do: books

    (portal ++ books_only) |> Enum.uniq_by(&document_ref/1)
  end

  # 2B documents routed to human, deduped (an ambiguous pair lists the same
  # candidate from both books rows).
  defp awaiting_2b_invoices(recon) do
    recon["needs_human"]
    |> Enum.flat_map(fn e ->
      case e["candidates"] |> List.wrap() |> List.first() || e["gstr2b"] do
        nil -> []
        g -> [g]
      end
    end)
    |> Enum.uniq_by(&document_ref/1)
  end

  defp document_ref(document) do
    {invoice_key(document), document["taxable_paise"], document["total_paise"],
     document["tax_paise"]}
  end

  defp available_document?(document), do: document_type(document) in ~w(invoice debit_note)

  defp document_type(%{"document_type" => type})
       when type in ~w(invoice credit_note debit_note),
       do: type

  defp document_type(_legacy_invoice), do: "invoice"

  # The block candidates for a month: one per full-block flag (personal / state)
  # staking the row's whole tax, plus ONE per duplicate GROUP staking the excess
  # (N-1 copies), never one per copy — a group is a single accounting decision
  # ("keep one, drop the rest").
  defp block_candidates(rows) do
    full =
      for row <- rows,
          document_type(row) != "credit_note",
          flag <- row["flags"] || [],
          flag["code"] in @full_block do
        %{
          "block_id" => block_id(row["id"], flag["code"]),
          "code" => flag["code"],
          "section" => flag["section"],
          "vendor" => row["vendor_name"],
          "document_type" => document_type(row),
          "invoice_number" => row["invoice_number"],
          "tax_paise" => row_tax(row),
          "tax_heads" => row_heads(row, 1),
          "reason" => flag["reason"],
          "in_ceiling" => in_ceiling?(row)
        }
      end

    full ++ duplicate_blocks(rows)
  end

  # Whether this row's tax is inside `ceiling_paise/1`. A books bill the portal
  # never reported is not: there is no credit to withhold, so blocking it must
  # not move the claimable figure.
  #
  # Only `in_books_not_2b` is outside. Anything else — including a row whose
  # bucket is absent — counts as inside, because the failure modes are not
  # symmetric: treating 2B-backed credit as outside silently *keeps* a credit
  # the reviewer explicitly blocked, while the reverse produces the impossible
  # figure that made this visible in the first place.
  defp in_ceiling?(row),
    do: row["bucket"] != "in_books_not_2b" and document_type(row) != "credit_note"

  # One block per duplicate group, keyed on the group's kept row, staking the
  # excess (N-1) copies' tax. The excess is what claiming every copy would
  # over-claim; keeping one copy is a real bill.
  defp duplicate_blocks(rows) do
    rows
    |> Enum.filter(fn r -> Enum.any?(r["flags"] || [], &(&1["code"] == "duplicate_invoice")) end)
    |> Enum.reject(&(document_type(&1) == "credit_note"))
    |> Enum.group_by(fn r -> {document_type(r), r["vendor_gstin"], norm(r["invoice_number"])} end)
    |> Enum.map(fn {_key, group} ->
      keep = Enum.min_by(group, & &1["id"])
      n = length(group)
      dup_flag = Enum.find(keep["flags"], &(&1["code"] == "duplicate_invoice"))

      %{
        "block_id" => block_id(keep["id"], "duplicate_invoice"),
        "code" => "duplicate_invoice",
        "section" => dup_flag["section"],
        "vendor" => keep["vendor_name"],
        "document_type" => document_type(keep),
        "invoice_number" => keep["invoice_number"],
        "tax_paise" => row_tax(keep) * (n - 1),
        "tax_heads" => row_heads(keep, n - 1),
        "reason" => dup_flag["reason"],
        # Never inside the ceiling, even when the kept row is matched. The
        # ceiling counts 2B entries, and a group of N scans of one bill has at
        # most one — the portal reported the invoice once. So the excess copies
        # are credit the 2B never carried, and the over-claim this block exists
        # to prevent was already prevented by the ceiling.
        #
        # Reading it off the kept row instead staked (N-1) copies against a
        # ceiling holding one, which the partition then had to clamp — and the
        # return, which does not clamp, reversed the whole excess and filed a
        # negative 4C that invented a cash demand out of a month with no
        # outward liability.
        "in_ceiling" => false
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

  defp row_heads(row, copies) do
    %{
      "igst" => (row["igst_paise"] || 0) * copies,
      "cgst" => (row["cgst_paise"] || 0) * copies,
      "sgst" => (row["sgst_paise"] || 0) * copies
    }
  end

  defp tax_sum(inv), do: (inv["tax_paise"] || %{}) |> Map.values() |> Enum.sum()
  defp norm(inum), do: InvoiceNumber.key(inum)
end
