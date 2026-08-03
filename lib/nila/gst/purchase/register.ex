defmodule Nila.Gst.Purchase.Register do
  @moduledoc """
  Builds purchase-register rows from the books invoices, the reconciliation
  result (`Nila.Gst.Purchase.Reconciliation`), and the validation flags (`Nila.Gst.Purchase.Flags`).

  Pure: plain maps in, plain maps out. The row shape is the single source for
  every register rendering — the month's register table, the Excel deliverable
  — so the surfaces cannot drift.
  """

  alias Nila.Formatters

  # Flags a 2B match does not answer. Eligibility and duplication are verdicts
  # the portal never renders — it reports that a supply happened, not that the
  # credit is claimable — and HSN/rate validity is about what is written on the
  # bill, which a value match does not check. Everything absent from this list
  # (OCR confidence, arithmetic, subtotal breakdown, an odd-looking invoice
  # number) is a doubt about reading the bill correctly, and a portal record
  # agreeing field-for-field is stronger evidence than that doubt.
  @unresolved_by_match ~w(
    personal_expense_17_5
    gstin_state_mismatch
    duplicate_invoice
    invalid_gstin
    missing_gstin
    name_gstin_mismatch
    own_gstin_as_vendor
    invalid_hsn_sac
    incomplete_hsn_sac
    missing_hsn_sac
    hsn_implausible
    zero_value_row
    statutory_rate_review
    statutory_rate_mismatch
    rate_history_conflict
  )

  @bucket_labels %{
    "matched" => "Matched to 2B",
    "value_mismatch" => "Value differs from 2B",
    "needs_human" => "Needs a decision",
    "in_books_not_2b" => "Not in 2B",
    "in_2b_not_books" => "In 2B only"
  }

  @doc """
  One row per books invoice, in page order, followed by rows for 2B-only
  entries. Each row:

      %{
        "id", "pages", "images",
        "invoice_number", "invoice_date", "vendor_name", "vendor_gstin",
        "taxable_paise", "cgst_paise", "sgst_paise", "igst_paise", "total_paise",
        "bucket" => recon bucket key,
        "bucket_label" => human label,
        "accepted_reason" => audited unmatched outcome or nil,
        "verdict" => short operator-language table text,
        "recon_note" => full engine reasoning or match detail,
        "next_action" => drafted follow-up or nil,
        "flags" => [%{"code", "severity", "reason"}],
        "flag_summary" => "code, code" or nil
      }
  """
  def rows(invoices, recon, flags_by_id) do
    bucket_index = bucket_index(recon)

    books_rows =
      invoices
      |> Enum.sort_by(&List.first(&1["pages"] || [0]))
      |> Enum.map(fn inv ->
        {bucket, entry} = Map.get(bucket_index, inv["id"], {"in_books_not_2b", nil})
        flags = Map.get(flags_by_id, inv["id"], [])

        %{
          "id" => inv["id"],
          "pages" => inv["pages"] || [],
          "images" => inv["images"] || [],
          "invoice_number" => inv["invoice_number"],
          "invoice_date" => inv["invoice_date"],
          "vendor_name" => inv["vendor_name"],
          "vendor_gstin" => inv["vendor_gstin"],
          "taxable_paise" => inv["taxable_paise"] || 0,
          "cgst_paise" => tax(inv, "cgst"),
          "sgst_paise" => tax(inv, "sgst"),
          "igst_paise" => tax(inv, "igst"),
          "total_paise" => inv["total_paise"] || 0,
          "bucket" => bucket,
          "bucket_label" => bucket_label(bucket, flags),
          "accepted_reason" => entry && entry["accepted_reason"],
          "verdict" => verdict(bucket, entry, flags),
          "recon_note" => recon_note(bucket, entry),
          "next_action" => entry && entry["next_action"],
          "flags" => Enum.map(flags, &Map.take(&1, ["code", "severity", "reason", "section"])),
          "flag_summary" => flag_summary(flags)
        }
      end)

    books_rows ++ g2b_only_rows(recon)
  end

  @doc """
  The web-facing counts *and money* for a summary.

  Counts alone cannot answer the reviewer's actual question ("what is my ITC
  position and what is riding on the open items"), so the rupee fields ride
  along: `total_tax_paise` is the month's whole ITC, `matched_tax_paise` is
  settled tax, `open_tax_paise` is the tax on rows still needing a decision.
  All come straight from `summary/1`; older summaries and pre-money signoff
  snapshots read 0 with `itc_money_known?` false, so a surface can say the
  figure is missing instead of asserting it is nothing.

  `rows` is every register line; `invoices` is only the books ones. A 2B-only
  line is a bill the books have never seen, so counting it as an invoice told
  the reviewer the client supplied documents they did not supply.
  `gstr2b_only` is that difference, and it is a completeness fact in its own
  right: bills the portal knows about that nobody has sent us.

  `need_decision`, `awaiting_bills` and `value_disputes` split the open pile by
  who owns the next move, and a row earns a place in `need_decision` only when a
  human's answer would change what gets filed.

  A 2B-only row is built with no `id` and no images: nothing to open, nothing to
  compare, no judgement to record. Its next move belongs to the client.

  A value mismatch is already paired — the engine matched it on GSTIN and
  invoice number, and only the amounts differ. ITC is claimable as reflected in
  the 2B, so the return takes the 2B figure whether or not anyone opens the row.
  That makes the delta a finding to report and a vendor to chase, not a fork in
  the return. Blocking a signature on it would be blocking on work that changes
  nothing.

  All three stay open (`open_row?/1`), because the money behind them is not
  settled and the register must keep saying so.

  The rupee split of that open money is only meaningful when
  `open_money_split_known?` is true — see the note on `decision_tax_paise`.
  """
  def stats(summary) do
    buckets = summary["buckets"] || %{}
    rows = buckets |> Map.values() |> Enum.sum()
    gstr2b_only = buckets["in_2b_not_books"] || 0
    matched = buckets["matched"] || 0
    matched_tax = summary["matched_tax_paise"] || 0
    open_tax = summary["open_tax_paise"] || 0

    total_tax = summary["total_tax_paise"] || matched_tax + open_tax

    open = rows - matched - (summary["accepted_unmatched"] || 0)
    # Accepted 2B-only rows have been ruled on, so they are neither a decision
    # nor a bill to chase. Subtracting them here is what keeps this split equal
    # to `awaiting_bill?/1` counted over the rows: deriving it as
    # `min(gstr2b_only, open)` counted audited rows as still-missing bills and
    # took the difference out of `need_decision`, inverting both numbers.
    awaiting_bills = gstr2b_only - (summary["accepted_gstr2b_only"] || 0)
    awaiting_bills_tax = summary["awaiting_bills_tax_paise"] || 0
    value_disputes = buckets["value_mismatch"] || 0
    value_dispute_tax = summary["value_dispute_tax_paise"] || 0
    # Whether the split of the open money is trustworthy, which is not the same
    # question as whether it is zero. A snapshot frozen before these fields
    # existed reads 0 for both subsets, and `decision_tax_paise` then absorbs
    # them silently — it is a subtraction, so it yields a plausible positive
    # number rather than an obvious ₹0. Only the difference between an absent
    # key and a zero one can tell those apart, and it is gone one line later, so
    # it is recorded here while it still exists.
    split_known? =
      Map.has_key?(summary, "awaiting_bills_tax_paise") or
        Map.has_key?(summary, "value_dispute_tax_paise") or
        open_tax == 0

    # Whether the month's ITC was recorded at all, which is a different question
    # from whether it is zero. A snapshot frozen before any of these fields
    # existed reads 0 for every one of them, and `settled_tax_paise` subtracts
    # one absence from another, so a page states "₹0 of ITC this month" beside a
    # register listing a dozen bills — a pair that cannot both be true, printed
    # in the confident voice. The bucket counts survived that freeze and the
    # money did not, so only the keys can tell absent from zero, and they are
    # gone by the time the map is built. An empty register is the one case where
    # ₹0 is not a guess: nothing to sum, nothing to be wrong about.
    itc_money_known? =
      Map.has_key?(summary, "total_tax_paise") or
        Map.has_key?(summary, "matched_tax_paise") or
        Map.has_key?(summary, "open_tax_paise") or
        rows == 0

    %{
      rows: rows,
      invoices: rows - gstr2b_only,
      gstr2b_only: gstr2b_only,
      matched: matched,
      open: open,
      need_decision: open - awaiting_bills - value_disputes,
      awaiting_bills: awaiting_bills,
      value_disputes: value_disputes,
      taxable_paise: summary["taxable_paise"] || 0,
      # Summaries written before `total_tax_paise` existed fall back to the two
      # fields they do have. That understates by the accepted rows, but it can
      # never read ₹0 next to a live open figure, which is the one way this
      # number can actively mislead.
      total_tax_paise: total_tax,
      matched_tax_paise: matched_tax,
      open_tax_paise: open_tax,
      # The money twin of the count split. `open_tax_paise` stays the whole open
      # pot so the partition still closes; this names the part of it that no
      # decision can move, only a bill arriving.
      awaiting_bills_tax_paise: awaiting_bills_tax,
      value_dispute_tax_paise: value_dispute_tax,
      # Why the month's ITC and the 2B ceiling differ. Absent from a snapshot
      # frozen before it existed, which reads the same as a genuine zero — so
      # `unreported_by_vendor_known?` says which, and a surface draws the line
      # only when the figure means something.
      unreported_by_vendor_tax_paise: summary["unreported_by_vendor_tax_paise"] || 0,
      unreported_by_vendor_known?: Map.has_key?(summary, "unreported_by_vendor_tax_paise"),
      # Both partitions still close on a pre-change snapshot, and the counts are
      # right there because the buckets always existed. The money is not: read
      # `open_money_split_known?` before showing any of these three as a
      # breakdown. A signed month is immutable, so this is a reading of history
      # rather than a live figure.
      decision_tax_paise: open_tax - awaiting_bills_tax - value_dispute_tax,
      open_money_split_known?: split_known?,
      # `matched` and `open` are not complements — audited-accepted rows are in
      # neither, so a reader adding the two visible subsets lands short of the
      # month. `settled` is the exact complement of `open` (the money-side twin
      # of `open_row?/1`), so a surface can show one whole and two parts that
      # actually close.
      settled_tax_paise: total_tax - open_tax,
      # Guards all three of the figures above. They are one fact from one place
      # — the register's tax — so they are absent together or present together.
      itc_money_known?: itc_money_known?
    }
  end

  @doc """
  How many rows still need a human decision.

  Collection rows are excluded: see `stats/1`. `open/1` is the whole open pile
  when a caller wants both halves.
  """
  def need_decision(summary), do: stats(summary).need_decision

  @doc "Every row still unsettled — decisions plus bills nobody has supplied."
  def open(summary), do: stats(summary).open

  @doc "Bucket counts plus flag totals for the cover/status page."
  def summary(rows) do
    %{
      "total_invoices" => Enum.count(rows, &(&1["bucket"] != "in_2b_not_books")),
      "buckets" => Enum.frequencies_by(rows, & &1["bucket"]),
      "accepted_unmatched" => Enum.count(rows, &(&1["accepted_reason"] != nil)),
      # The accepted share of the 2B-only bucket, so `stats/1` can split the
      # open pile without replaying rows.
      "accepted_gstr2b_only" =>
        Enum.count(rows, &(&1["bucket"] == "in_2b_not_books" and &1["accepted_reason"] != nil)),
      "flag_counts" =>
        rows
        |> Enum.flat_map(& &1["flags"])
        |> Enum.frequencies_by(& &1["code"]),
      "taxable_paise" =>
        rows
        |> Enum.reject(&(&1["bucket"] == "in_2b_not_books"))
        |> Enum.map(& &1["taxable_paise"])
        |> Enum.sum(),
      # The month's whole ITC, and the anchor the other two rupee fields are
      # subsets of: matched + accepted + open closes exactly, because those
      # three predicates partition the register. Without it the page can only
      # show two figures that sum to less than the month by whatever sits in
      # audited-accepted rows — a gap a reviewer reading them side by side has
      # no way to see.
      "total_tax_paise" => rows |> Enum.map(&row_tax/1) |> Enum.sum(),
      "matched_tax_paise" =>
        rows
        |> Enum.filter(&(&1["bucket"] == "matched"))
        |> Enum.map(&row_tax/1)
        |> Enum.sum(),
      # The counterpart of need_decision, in rupees: what is still riding on
      # the undecided rows. Same predicate as the count (unmatched and not
      # audited-accepted), so the two can never disagree.
      "open_tax_paise" =>
        rows
        |> Enum.filter(&open_row?/1)
        |> Enum.map(&row_tax/1)
        |> Enum.sum(),
      # The share of the open pot riding on a bill arriving rather than on
      # anyone's judgement. Same predicate as the count, so the two agree.
      "awaiting_bills_tax_paise" =>
        rows
        |> Enum.filter(&awaiting_bill?/1)
        |> Enum.map(&row_tax/1)
        |> Enum.sum(),
      # Books-side credit with nothing in the 2B behind it: bills the portal
      # never reported at all, plus the books-side value of rows still hunting
      # for their counterpart. It is the difference between the month's own ITC
      # and the 2B ceiling, and it had no name — a reader could only find it by
      # subtracting two totals that looked like they should agree. It is also
      # the most actionable figure on the page: not claimable this month, and
      # each row is a vendor who has not filed.
      "unreported_by_vendor_tax_paise" =>
        rows
        |> Enum.filter(&(&1["bucket"] in ["in_books_not_2b", "needs_human"]))
        |> Enum.map(&row_tax/1)
        |> Enum.sum(),
      # Tax on rows paired to a 2B that disagrees on amount. Still open money —
      # the register reports the delta — but not money a decision can move.
      "value_dispute_tax_paise" =>
        rows
        |> Enum.filter(&value_dispute?/1)
        |> Enum.map(&row_tax/1)
        |> Enum.sum()
    }
  end

  @doc "Whether a row is still unsettled — a decision to make, or a bill to collect."
  def open_row?(row), do: row["bucket"] != "matched" and row["accepted_reason"] == nil

  @doc """
  Whether a row is waiting on a bill nobody supplied rather than on a decision.

  The portal reported a supply and the books have no document for it, so there
  is nothing to inspect and nothing to judge — the next move is a request to the
  client.
  """
  def awaiting_bill?(row), do: row["bucket"] == "in_2b_not_books" and open_row?(row)

  @doc """
  Whether a row's amounts disagree with the 2B it is already paired to.

  The credit follows the 2B either way, so no answer a reviewer gives changes
  the return. It is a finding to report and a vendor to chase — and if the
  credit should actually be withheld, that is `block_itc`, which already exists.
  """
  def value_dispute?(row), do: row["bucket"] == "value_mismatch" and open_row?(row)

  @doc """
  Whether a row is an open decision whose answer changes what gets filed.

  The one predicate a signature gate should read: a row nobody's judgement can
  move must not block the return.
  """
  def decision_row?(row),
    do: open_row?(row) and not awaiting_bill?(row) and not value_dispute?(row)

  @doc """
  Whether a row has anything to say beyond its bucket — an open decision, or a
  validation flag. Drives whether the note column speaks: a flag is always worth
  *reading*, even when `needs_review?/1` decides it is not worth alarm.
  """
  def annotated_row?(row), do: open_row?(row) or row["flags"] not in [nil, []]

  @doc """
  Whether a *matched* row still deserves a reviewer's eye.

  A match on GSTIN + invoice number + value is the government's own copy of the
  bill agreeing with the books on every field the flag could doubt. That settles
  transcription doubt — how sure the model felt is not evidence against a record
  the portal independently confirms — so those codes go quiet once matched.

  What a 2B match cannot answer stays loud: the portal reports a supply, it does
  not rule on whether the credit is claimable (17(5) personal use, a place-of-
  supply contradiction), whether the same bill was counted twice, or whether the
  HSN and rate on it are legal. Those are the reviewer's call however cleanly the
  row matched.

  This mirrors why the ⚠ and the row accent were narrowed to `open_row?/1`:
  when every flag painted a row, alarm meant nothing.
  """
  def needs_review?(row) do
    row["bucket"] == "matched" and
      Enum.any?(row["flags"] || [], &(&1["code"] in @unresolved_by_match))
  end

  # The bucket is a *matching* verdict, and "Matched to 2B" beside a note
  # reading "GSTIN doesn't check out" is read as "reviewed and safe". The label
  # is stored, so a surface that renders it verbatim — a signoff snapshot, a
  # deliverable — would otherwise repeat the clean claim the page no longer
  # makes.
  defp bucket_label("matched", flags) do
    if Enum.any?(flags, &(&1["code"] in @unresolved_by_match)),
      do: "Matched · needs review",
      else: @bucket_labels["matched"]
  end

  defp bucket_label(bucket, _flags), do: @bucket_labels[bucket]

  @doc "Total tax on a register row."
  def row_tax(row),
    do: (row["cgst_paise"] || 0) + (row["sgst_paise"] || 0) + (row["igst_paise"] || 0)

  defp bucket_index(recon) do
    for bucket <- ["matched", "value_mismatch", "needs_human", "in_books_not_2b"],
        entry <- recon[bucket] || [],
        books = entry["books"],
        books != nil,
        into: %{} do
      {books["id"], {bucket, entry}}
    end
  end

  defp g2b_only_rows(recon) do
    for entry <- recon["in_2b_not_books"] || [] do
      g = entry["gstr2b"] || entry

      %{
        "id" => nil,
        "pages" => [],
        "images" => [],
        "invoice_number" => g["invoice_number"],
        "invoice_date" => g["invoice_date"],
        "vendor_name" => g["vendor_name"],
        "vendor_gstin" => g["vendor_gstin"],
        "taxable_paise" => g["taxable_paise"] || 0,
        "cgst_paise" => tax(g, "cgst"),
        "sgst_paise" => tax(g, "sgst"),
        "igst_paise" => tax(g, "igst"),
        "total_paise" => g["total_paise"] || 0,
        "bucket" => "in_2b_not_books",
        "bucket_label" => @bucket_labels["in_2b_not_books"],
        "accepted_reason" => nil,
        "verdict" => verdict("in_2b_not_books", entry, []),
        "recon_note" => entry["reason"] && entry["reason"]["message"],
        "next_action" => entry["next_action"],
        "flags" => [],
        "flag_summary" => nil
      }
    end
  end

  defp recon_note("matched", entry) do
    case entry["match_basis"] do
      basis when is_list(basis) -> "matched on " <> Enum.join(basis, " + ")
      _ -> nil
    end
  end

  defp recon_note("value_mismatch", entry) do
    deltas =
      (entry["deltas"] || %{})
      |> Enum.reject(fn {_k, v} -> v == 0 end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k} #{format_delta(v)}" end)

    "differs from 2B: " <> deltas
  end

  defp recon_note(_bucket, entry) do
    entry && entry["reason"] && entry["reason"]["message"]
  end

  defp verdict(_bucket, _entry, [%{"code" => code} | _flags]),
    do: Formatters.issue_label(code)

  defp verdict("in_books_not_2b", %{"accepted_reason" => "await_2b"}, []),
    do: "Awaiting 2B"

  defp verdict("in_books_not_2b", %{"accepted_reason" => "not_claimable"}, []),
    do: "Not claimed this month"

  defp verdict(
         "needs_human",
         %{"reason" => %{"code" => "ambiguous_matches"}} = entry,
         []
       ) do
    case length(entry["candidates"] || []) do
      count when count > 0 -> "#{count} possible 2B matches"
      _count -> Formatters.recon_verdict("ambiguous_matches")
    end
  end

  defp verdict(bucket, entry, []) when bucket in ["matched", "value_mismatch"],
    do: recon_note(bucket, entry)

  defp verdict(_bucket, %{"reason" => %{"code" => code}}, []),
    do: Formatters.recon_verdict(code)

  defp verdict(_bucket, _entry, []), do: nil

  defp format_delta(paise) do
    sign = if paise > 0, do: "+", else: "-"
    sign <> Nila.Formatters.format_money_with_paise(abs(paise))
  end

  defp flag_summary([]), do: nil
  defp flag_summary(flags), do: Enum.map_join(flags, ", ", & &1["code"])

  defp tax(inv, key), do: get_in(inv, ["tax_paise", key]) || 0
end
