defmodule Nila.Gst.Intake.Preconditions do
  @moduledoc """
  What a packet has to satisfy before a month can be built on it, and the three
  answers when it doesn't.

  **A period mismatch is a precondition, not an exception.** An exception is a
  judgement the reviewer is qualified to make; a precondition is a question
  about whether the work is even the right work. April's purchase packet
  uploaded a second time into June produced twenty-two identical orange dots,
  each offering verbs that are wrong for both halves of the pile ("the vendor
  hasn't filed it yet" for a bill from four months ago) — twenty-two exceptions
  laundered out of one question nobody was asked. Preconditions are answered
  once, before any exception exists.

  Three checks, two severities:

    * `period_mismatch` — most of the packet is dated outside the month it was
      filed under. A **question**, never a scolding: ITC on an April invoice may
      legally be availed up to 30 Nov of the following FY, and late-arriving
      bills are ordinary. The threshold (more than half the packet, and at least
      three bills) exists so one straggler from last month never trips it.
    * `cross_month_duplicate` — invoices already booked in another month of the
      same client, same number, same date. Keyed with `Nila.Fuzzy.normalize/1`,
      the same normalization `Purchase.Flags` uses within a packet, and scoped
      to the client — two clients legitimately hold the same vendor's bill
      number. Its severity is **derived, not assumed** (`"severity"` on the
      finding). The old grade was a flat error, on the reasoning that the same
      invoice in two months double-claims the credit — but that is only true
      once the other month has been *filed*. Against an unfiled draft nothing
      has been claimed and nothing is wrong yet; two drafts hold the same
      packet and one of them is in the wrong place, which is a **question** of
      exactly the same kind as `period_mismatch`. Against a filed month it is
      an **error**, and no reading of the law makes that fine.
    * `zero_overlap` — books side non-empty, 2B side non-empty, matched count
      exactly zero. Deliberately threshold-free: a match *rate* is a constant
      that has to be recalibrated as the corpus grows, while two populated sets
      with nothing in common needs no calibration at all. It is the general net
      under the other two — wrong client's file, a 2B for another GSTIN, a sales
      packet dropped in the purchase slot — and it reports what was observed
      ("14 bills, 8 2B entries, nothing matched"), never a cause it cannot know.

  Both packet checks read the dump's own extracted invoices, so they cost the
  extraction they follow. That is worth saying out loud: we pay for the read,
  then refuse to build a month on it. The alternative — asking before reading —
  can only ask about the filename, which is exactly the guess that failed.

  Which check runs is a property of the dump's kind, so `check/1` enumerates
  every kind rather than falling through a catch-all. A catch-all here answers
  "nothing wrong" for the kinds nobody thought about, and that is exactly how
  sales went unguarded while a June packet filed itself into December.

  `zero_overlap` is purchase-only because it needs a second side to compare
  against, and sales has none. The other two run on every packet: sales invoice
  dates are parsed at extraction (`Gstr1.normalize_invoice/1`), so a sales
  packet answers the period question in the same terms as a bill packet, and a
  sales invoice declared in two months is the same error read from the other
  side of the ledger.
  """

  alias Nila.Fuzzy
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Purchase.Reconciliation
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Storage

  # A two-bill packet where both are old is noise; fourteen of fourteen is a
  # fact. The floor is what keeps the check from firing on noise.
  @minimum_outside 3

  # Most severe first: the error owns the headline, whatever else also fired.
  @kinds ~w(cross_month_duplicate zero_overlap period_mismatch)

  @doc """
  The findings for a freshly extracted dump, or `nil` when the month may be
  built on it.

  Shape (only the fields whose check fired):

      %{
        "kind" => "cross_month_duplicate",
        "kinds" => ["period_mismatch", "cross_month_duplicate", "zero_overlap"],
        "total" => 14,
        "outside_period" => 14,
        "modal_period" => "2026-04",
        "outside_periods" => ["2026-01", "2026-02", "2026-03", "2026-04"],
        "duplicate_of" => %{"period" => "2026-04", "count" => 14},
        "severity" => "error",
        "observed" => %{"books" => 14, "gstr2b" => 8, "matched" => 0}
      }

  `"severity"` is written only by `cross_month_duplicate`, the one check whose
  grade is not a property of its own kind. A finding without the key predates
  the derivation and is read as the error it was recorded as.
  """
  # Every kind in `Dump.kinds/0`, listed on purpose. A fourth kind raises here
  # rather than being waved through, and the test that walks `Dump.kinds/0`
  # catches it before a worker ever does.
  def check(%Dump{kind: kind} = dump) when kind in ~w(purchase sales gstr2b filed_gstr1) do
    if answered?(dump), do: nil, else: findings(dump)
  end

  defp findings(%Dump{kind: "gstr2b"} = dump),
    do: merge([zero_overlap(dump)], dump, dump.invoices)

  # A filed return is declared, structured, and shape-checked at extraction;
  # there is no bill pile to interrogate, so no questions to ask.
  defp findings(%Dump{kind: "filed_gstr1"}), do: nil

  defp findings(%Dump{kind: "sales"} = dump) do
    invoices = Enum.map(dump.invoices, &Dumps.rehydrate/1)

    merge(
      [period_mismatch(dump, invoices), cross_month_duplicate(dump, invoices)],
      dump,
      invoices
    )
  end

  defp findings(%Dump{kind: "purchase"} = dump) do
    invoices = Enum.map(dump.invoices, &Dumps.rehydrate/1)

    [period_mismatch(dump, invoices), cross_month_duplicate(dump, invoices), zero_overlap(dump)]
    |> merge(dump, invoices)
  end

  defp merge(findings, dump, invoices) do
    case Enum.filter(findings, & &1) do
      [] ->
        nil

      fired ->
        kinds = Enum.map(fired, & &1["kind"])

        fired
        |> Enum.reduce(%{}, &Map.merge(&2, Map.delete(&1, "kind")))
        |> Map.put("kind", Enum.find(@kinds, &(&1 in kinds)))
        |> Map.put("kinds", Enum.filter(@kinds, &(&1 in kinds)))
        |> Map.put("total", length(invoices))
        |> Map.put("period", dump.period)
    end
  end

  # ---------------------------------------------------------------------------
  # a. Dates outside the period — a question.
  # ---------------------------------------------------------------------------

  # The majority is taken over the invoices that *have* a date, not over every
  # entry on the dump. Rows the check cannot date — a cover sheet the sales path
  # maps like any other page, an unreadable date — say nothing either way, and
  # counting them in the denominator only ever votes against asking. Four June
  # bills behind four junk pages is still four bills in the wrong month.
  defp period_mismatch(%Dump{} = dump, invoices) do
    dated = for invoice <- invoices, period = period_of(invoice), do: period
    outside = Enum.reject(dated, &(&1 == dump.period))
    count = length(outside)

    if count >= @minimum_outside and count * 2 > length(dated) do
      %{
        "kind" => "period_mismatch",
        "outside_period" => count,
        "modal_period" => modal(outside),
        # The months the *outside* bills carry, so the sentence a reviewer reads
        # ("dated Jan–Apr") describes the bills the question is about.
        "outside_periods" => outside |> Enum.uniq() |> Enum.sort()
      }
    end
  end

  defp period_of(%{"invoice_date" => %Date{} = date}), do: Elixir.Calendar.strftime(date, "%Y-%m")
  defp period_of(_invoice), do: nil

  defp modal(periods) do
    periods
    |> Enum.frequencies()
    |> Enum.max_by(fn {period, count} -> {count, period} end)
    |> elem(0)
  end

  # ---------------------------------------------------------------------------
  # b. The same bill in two months — an error.
  # ---------------------------------------------------------------------------

  defp cross_month_duplicate(%Dump{} = dump, invoices) do
    keys = invoice_keys(invoices)

    if MapSet.size(keys) > 0 do
      dump.org_id
      |> Dumps.extracted_elsewhere(dump.client_id, dump.period, dump.kind)
      |> Enum.group_by(& &1.period)
      |> Enum.map(fn {period, dumps} ->
        booked =
          dumps
          |> Enum.flat_map(& &1.invoices)
          |> Enum.map(&Dumps.rehydrate/1)
          |> invoice_keys()

        {period, MapSet.size(MapSet.intersection(keys, booked))}
      end)
      |> Enum.reject(fn {_period, count} -> count == 0 end)
      |> Enum.sort_by(fn {period, count} -> {-count, period} end)
      |> case do
        [] ->
          nil

        [{period, count} | _rest] ->
          %{
            "kind" => "cross_month_duplicate",
            "duplicate_of" => %{"period" => period, "count" => count},
            "severity" => severity(dump, period)
          }
      end
    end
  end

  # The grade is a fact about the *other* month, so it is read from that month
  # rather than asserted from the shape of the match. Filed means the return
  # went out holding these invoices; anything else — worked, reviewed, signed,
  # not yet created — means nothing has been declared and the two copies are
  # still both drafts.
  defp severity(%Dump{kind: "sales"} = dump, period),
    do: grade(SalesMonths.get_by_period(dump.org_id, dump.client_id, period))

  defp severity(%Dump{} = dump, period),
    do: grade(PurchaseMonths.get_by_period(dump.org_id, dump.client_id, period))

  defp grade({:ok, %{filed_at: filed_at}}) when not is_nil(filed_at), do: "error"
  defp grade(_unfiled), do: "question"

  defp invoice_keys(invoices) do
    for %{"invoice_date" => %Date{} = date} = invoice <- invoices,
        number = invoice["invoice_number"],
        is_binary(number),
        normalized = Fuzzy.normalize(number),
        normalized != "",
        into: MapSet.new() do
      {normalized, Date.to_iso8601(date)}
    end
  end

  # ---------------------------------------------------------------------------
  # c. Two populated sides with nothing in common — a question about the pair.
  # ---------------------------------------------------------------------------

  defp zero_overlap(%Dump{} = dump) do
    books = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "purchase")

    gstr2b =
      dump.org_id
      |> Dumps.effective(dump.client_id, dump.period, "gstr2b")
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)

    # Both sides must be populated. A month before its 2B arrives is an ordinary
    # state, and a check that fires there is a nag on half the product's months.
    if books != [] and gstr2b != [] and not settled?(dump, "zero_overlap") do
      recon = Reconciliation.reconcile(books, gstr2b)

      if recon["matched"] == [] do
        %{
          "kind" => "zero_overlap",
          "observed" => %{
            "books" => length(books),
            "gstr2b" => length(gstr2b),
            "matched" => 0
          }
        }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The three answers. Routing decisions, not data edits: the extraction stands.
  # ---------------------------------------------------------------------------

  @doc """
  Answer: the packet belongs to `period`. Repoints the dump and hands it back to
  the worker, which runs the same wall check every arrival runs — a signed
  destination holds it, a filed one refuses it, and both are already built.

  Evidence images are copied to the destination month's prefix so the moved
  bills keep their scans; re-reading the packet to regenerate them would pay a
  provider bill for a fact we already have.
  """
  def move(%Dump{status: "needs_confirmation"} = dump, period, user_id) do
    answer = answer(dump, "move", %{"moved_from" => dump.period}, user_id)

    with {:ok, moved} <- Dumps.confirm_moved(dump, period, answer) do
      move_evidence(moved, dump.period)
      {:ok, moved}
    end
  end

  def move(%Dump{}, _period, _user_id), do: {:error, :not_in_question}

  @doc """
  Answer: it belongs here, and here is why. First-class, not a grudging escape —
  availing an April credit in June is legal and the reviewer may know exactly
  why. The recorded reason is what makes it defensible at sign-off.
  """
  def keep(%Dump{status: "needs_confirmation"} = dump, reason, user_id) do
    case String.trim(to_string(reason)) do
      "" -> {:error, :reason_required}
      reason -> Dumps.confirm_kept(dump, answer(dump, "keep", %{"reason" => reason}, user_id))
    end
  end

  def keep(%Dump{}, _reason, _user_id), do: {:error, :not_in_question}

  @doc "Answer: it was uploaded twice. Terminal, and no month is built from it."
  def discard(%Dump{status: "needs_confirmation"} = dump, user_id),
    do: Dumps.mark_discarded(dump, answer(dump, "discard", %{}, user_id))

  def discard(%Dump{}, _user_id), do: {:error, :not_in_question}

  defp answer(dump, verb, extra, user_id) do
    finding = Dumps.precondition(dump) || %{}

    Map.merge(extra, %{
      "answer" => verb,
      "kinds" => finding["kinds"] || [],
      "finding" => finding,
      "answered_by_id" => user_id,
      "answered_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  # A dump the reviewer already answered is not asked again — that is the whole
  # difference between a question and a nag. A "move" is deliberately not an
  # answer to the destination's question: the packet lands there like any other
  # arrival, and if it is wrong there too it says so.
  defp answered?(%Dump{} = dump) do
    match?(%{"answer" => "keep"}, Dumps.precondition_answer(dump))
  end

  # The pairing question belongs to the month, not to the arrival that happened
  # to raise it. Once answered, a straggler must not reopen it.
  defp settled?(%Dump{} = dump, kind) do
    dump.org_id
    |> Dumps.list(dump.client_id, dump.period)
    |> Enum.any?(fn other ->
      case Dumps.precondition_answer(other) do
        %{"answer" => "keep", "kinds" => kinds} -> kind in kinds
        _other -> false
      end
    end)
  end

  # Purchase names its pages in a list, sales in a scalar, and the two write to
  # different prefixes — so the move has to know both. A 2B carries no scans.
  defp move_evidence(%Dump{kind: "gstr2b"}, _from_period), do: :ok

  defp move_evidence(%Dump{} = dump, from_period) do
    key_fun = evidence_key_fun(dump.kind)

    for invoice <- dump.invoices, basename <- basenames(invoice) do
      from = key_fun.(dump.org_id, dump.client_id, from_period, basename)
      to = key_fun.(dump.org_id, dump.client_id, dump.period, basename)

      with {:ok, bytes} <- Storage.get(from) do
        Storage.put(to, bytes, content_type: content_type(basename))
      end
    end

    :ok
  end

  defp evidence_key_fun("purchase"), do: &PurchaseMonths.evidence_key/4
  defp evidence_key_fun("sales"), do: &SalesMonths.evidence_key/4

  defp basenames(invoice) do
    case invoice["images"] || invoice["image"] do
      names when is_list(names) -> names
      name when is_binary(name) -> [name]
      _none -> []
    end
  end

  defp content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
      _other -> "application/octet-stream"
    end
  end
end
