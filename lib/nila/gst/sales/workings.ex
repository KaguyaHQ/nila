defmodule Nila.Gst.Sales.Workings do
  @moduledoc """
  Layers human resolutions over a worked sales month to produce the *effective*
  outward month: corrected invoices, re-validated issues, and the re-derived
  portal-shaped GSTR-1. The sales mirror of `Nila.Gst.Purchase.Workings`.

  The stored `invoices`/`issues`/`derived_gstr1` are machine truth and are
  never mutated. Corrections go through the real `Gstr1.apply_corrections/3`
  (never a reimplementation). The flagged-field discipline is stricter here
  than in the eval: the eval applies a silent-error correction and reports it;
  production review refuses to apply it at all — an unflagged correction is
  returned in `silent_errors`, never folded into the month.
  Issues and the derived return are then recomputed by the real engine, and
  confirmed issues are marked `"resolved"` rather than dropped — the audit
  surface keeps showing what the machine found and what the human decided.

  Pure: invoices + resolutions in, effective month out. Latest resolution per
  target wins (append-only store, so ordering is by insertion).
  """

  alias Nila.Gst.Hsn.DescriptionSignal
  alias Nila.Gst.Hsn.Validation
  alias Nila.Gst.Issues
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Rates.Validation, as: RateValidation
  alias Nila.Gst.Replay
  alias Nila.Gst.Sales.Gstr1

  @doc """
  Applies resolutions (append-only, oldest first) to a sales month's invoices,
  returning the effective month. `resolutions` are plain maps with string keys
  mirroring `Nila.Gst.Sales.Resolution` (`"verb"`, `"target"`, `"payload"`).
  `header` is the `Gstr1.derive/2` second argument (production header).

  Returns explicit `source_invoices`, `active_invoices`, and
  `duplicate_copies` projections. `invoices` remains the effective source-row
  projection for compatibility and audit output; only `active_invoices` feed
  validation and derivation. Issues carry `"status"` of `"open" | "resolved"`.
  `decisions` is the effective `%{target => verb}` map, `corrections` the
  effective correction resolutions in apply order, and `flagged` the
  `Gstr1.flagged_fields/2` set on pristine source identity.
  """
  def materialize(invoices, resolutions, header, document_issues \\ [], opts \\ [])

  def materialize(invoices, resolutions, header, document_issues, %{} = compliance) do
    materialize(invoices, resolutions, header, document_issues, compliance: compliance)
  end

  def materialize(invoices, resolutions, header, document_issues, opts) when is_list(opts) do
    compliance = Keyword.get(opts, :compliance, %{})
    cess_evaluated = Keyword.get(opts, :cess_evaluated, true)

    pristine_source_invoices =
      invoices
      |> ensure_source_ids(Keyword.get(opts, :source_namespace, "legacy"))
      |> annotate_compliance(compliance)

    effective = Replay.drop_reopened(resolutions, "target")
    decisions = Replay.decisions(resolutions, "target")

    corrections =
      effective
      |> Enum.filter(&(&1["verb"] == "correct_field"))
      |> normalize_correction_targets(pristine_source_invoices)
      |> effective_corrections()

    correction_issues =
      Gstr1.validation_issues(pristine_source_invoices) ++
        Gstr1.duplicate_number_issues(pristine_source_invoices) ++
        compliance_issues(pristine_source_invoices, compliance)

    source_flagged = Gstr1.flagged_fields(pristine_source_invoices, correction_issues)

    {legit, silent_errors} =
      corrections
      |> Enum.map(&correction_map/1)
      |> Enum.split_with(&Gstr1.correction_allowed?(source_flagged, &1["source_id"], &1["field"]))

    {corrected, _applied, [], _flags} =
      Gstr1.apply_corrections(pristine_source_invoices, legit, source_flagged)

    corrected = annotate_compliance(corrected, compliance)

    exclusions = Enum.filter(effective, &(&1["verb"] == "exclude_duplicate_copy"))
    {source_invoices, active_invoices, duplicate_copies} = apply_exclusions(corrected, exclusions)

    {printed_invoices, printed_active_invoices, _printed_copies} =
      apply_exclusions(pristine_source_invoices, exclusions)

    derived = Gstr1.derive(active_invoices, header)

    raw_issues =
      active_invoices
      |> Gstr1.validation_issues()
      |> Enum.concat(compliance_issues(active_invoices, compliance))
      |> Enum.concat(Gstr1.blocking_issues(active_invoices))
      |> Enum.concat(challenge_issues(effective, active_invoices))
      |> Enum.concat(cess_issues(cess_evaluated, active_invoices, effective))
      |> Enum.concat(completeness_issues(active_invoices, effective))
      |> Enum.concat(document_issues)
      |> Issues.normalize_all()
      |> collapse_by_target()

    confirmations =
      effective
      |> Replay.latest("target")
      |> Map.values()
      |> Enum.filter(&(&1["verb"] == "confirm_issue" and answered?(&1)))

    confirmed_keys =
      confirmed_issue_keys(confirmations, raw_issues, pristine_source_invoices)

    issues =
      raw_issues
      |> Enum.map(fn issue ->
        status =
          if not blocking?(issue) and MapSet.member?(confirmed_keys, issue_key(issue)),
            do: "resolved",
            else: "open"

        Map.put(issue, "status", status)
      end)
      |> sort_by_severity()

    %{
      invoices: source_invoices,
      source_invoices: source_invoices,
      active_invoices: active_invoices,
      printed_invoices: printed_invoices,
      printed_active_invoices: printed_active_invoices,
      duplicate_copies: duplicate_copies,
      issues: issues,
      derived: derived,
      decisions: decisions,
      corrections: corrections,
      flagged: with_legacy_flag_aliases(source_flagged, pristine_source_invoices),
      silent_errors: silent_errors
    }
  end

  @doc "Adds deterministic source IDs without mutating the stored invoice maps."
  def ensure_source_ids(invoices, namespace) do
    invoices
    |> Enum.with_index(1)
    |> Enum.map(fn {invoice, ordinal} ->
      Map.put_new(
        invoice,
        "id",
        "#{namespace}_inv_#{String.pad_leading(to_string(ordinal), 2, "0")}"
      )
    end)
  end

  defp annotate_compliance(invoices, compliance) do
    invoices
    |> annotate_hsn(compliance)
    |> annotate_rates(compliance)
  end

  defp annotate_hsn(invoices, %{directory: directory}) do
    invoices
    |> Validation.annotate_invoices(directory)
    # Shadow only: measured, never rendered. See `DescriptionSignal` for why the
    # staging matters — a false description conflict at `required` would
    # withhold a filing over a naming style.
    |> DescriptionSignal.observe(%{track: :sales})
  end

  defp annotate_hsn(invoices, _compliance), do: invoices

  defp annotate_rates(invoices, %{rate_directory: directory}),
    do: RateValidation.annotate_invoices(invoices, directory)

  defp annotate_rates(invoices, _compliance), do: invoices

  # What the month cannot see for itself.
  #
  # Every completeness signal until now was *internal consistency*: files
  # received, pages read, documents extracted, sequence gaps. One perfectly read
  # file can still be half a month, and no amount of internal agreement can tell
  # you that a credit note was issued and never sent to us.
  #
  # Not one lumped "anything else?" — each answer routes somewhere different.
  # Exports, SEZ and B2C stay separate because they map to three different
  # blocking codes, and a merged "yes" would tell Nila nothing about what is
  # actually present.
  @completeness_questions [
    %{
      key: "credit_or_debit_notes",
      question: "Were any credit or debit notes issued this month?",
      unsupported: "credit_note_unsupported",
      gap:
        "This return has no cdnr table, so a month containing credit or debit notes must be filed manually until that support lands."
    },
    %{
      key: "exports",
      question: "Were any export supplies made this month?",
      unsupported: "export_supply_unsupported",
      gap:
        "This return files B2B invoices only. An export would be filed as an ordinary taxable supply, which is wrong."
    },
    %{
      key: "sez_supplies",
      question: "Were any supplies made to an SEZ this month?",
      unsupported: "export_supply_unsupported",
      gap: "An SEZ supply files in its own table, which this return does not build."
    },
    %{
      key: "b2c_supplies",
      question: "Were any B2C supplies made this month?",
      unsupported: "b2c_supply_unsupported",
      gap:
        "This return files B2B invoices only. A B2C supply belongs in b2cs/b2cl, which it does not build."
    },
    %{
      key: "cancelled_documents",
      question: "Were any invoices cancelled this month?",
      unsupported: nil,
      gap: nil
    },
    %{
      key: "additional_series",
      question: "Is there a second invoice series we have not been sent?",
      unsupported: nil,
      gap: nil
    }
  ]

  @completeness_keys Enum.map(@completeness_questions, & &1.key)

  @doc "The completeness questions asked of every month, in order."
  def completeness_questions, do: @completeness_questions

  # Asked of an empty month too. Skipping it made a month with no invoices
  # `reviewable?` by vacuum — `Enum.all?([])` is true — so the GSTR-1 could be
  # approved with nobody having confirmed anything about any category. An empty
  # month is exactly where the questions carry the most weight: "no sales at all
  # this month" is a real claim a human should make, not a state Nila infers
  # from an empty pile. `completeness_scope/1` hashes the empty set to a stable
  # target, so the answers hold until documents actually arrive.
  defp completeness_issues(invoices, effective) do
    scope = completeness_scope(invoices)

    Enum.flat_map(@completeness_questions, fn q ->
      target = "#{q.key}|#{scope}"

      answer = completeness_answer(effective, target)

      # The question is always raised and `answered?/1` decides whether it
      # settles. That keeps the given answer on the page — a reviewer must be
      # able to see what they said and undo it — without an answered question
      # continuing to gate the month.
      [completeness_question_issue(q, target, answer) | completeness_gap_issues(q, answer)]
    end)
  end

  defp completeness_question_issue(q, target, answer) do
    %{
      "invoice" => nil,
      "code" => "completeness_unconfirmed",
      "level" => Issues.level_for("completeness_unconfirmed"),
      "message" => q.question,
      "fields" => [],
      "target" => target,
      "attestation_key" => q.key,
      "answer" => answer
    }
  end

  # A blocker that only says "Nila cannot handle this" is honest and
  # operationally useless — the cess lesson. Every yes names the next move.
  defp completeness_gap_issues(%{unsupported: nil}, _answer), do: []
  defp completeness_gap_issues(_q, answer) when answer != "yes", do: []

  defp completeness_gap_issues(q, _yes) do
    [
      %{
        "invoice" => nil,
        "code" => q.unsupported,
        "level" => Issues.level_for(q.unsupported),
        "message" => q.gap,
        "fields" => []
      }
    ]
  end

  defp completeness_answer(effective, target) do
    effective
    |> Enum.filter(&(&1["verb"] == "confirm_issue" and &1["target"] == target))
    |> List.last()
    |> case do
      nil -> nil
      confirmation -> get_in(confirmation, ["payload", "answer"])
    end
  end

  # Scoped to the invoice set, so a later pile reopens every question: an answer
  # given about one set of bills cannot speak for a set that has grown.
  defp completeness_scope(invoices) do
    invoices
    |> Enum.map(&"#{&1["id"]}|#{&1["invoice_number"]}")
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp cess_issues(true, _invoices, _effective), do: []

  defp cess_issues(false, invoices, effective) do
    target = cess_target(invoices)
    count = length(invoices)

    question = %{
      "invoice" => nil,
      "code" => "cess_not_evaluated",
      "level" => Issues.level_for("cess_not_evaluated"),
      "message" =>
        "Cess has not been checked on #{count} sales #{if count == 1, do: "invoice", else: "invoices"}. Confirm that none of them carries a cess-applicable supply.",
      "fields" => [],
      "target" => target
    }

    [question | cess_unsupported_issues(cess_answer(effective, target))]
  end

  # "Cess applies" is not a more severe version of "cess was not checked" — it is
  # the answer to it, which happens to uncover a capability gap. `derive_invoice`
  # hardcodes `"csamt" => 0` and `normalize_line` carries no cess field, so this
  # engine cannot file a cess-bearing return; that is the same family as a credit
  # note the return has no table for, and `blocking?` keeps anyone confirming it
  # away. Deriving it from the answer means `reopen` on the cess target discards
  # both without a second event.
  defp cess_unsupported_issues("cess_applies") do
    [
      %{
        "invoice" => nil,
        "code" => "cess_unsupported",
        "level" => Issues.level_for("cess_unsupported"),
        "message" =>
          "a cess-applicable supply was confirmed on this month's sales, and GSTR-1 derivation carries no cess — it would file every line at csamt 0",
        "fields" => []
      }
    ]
  end

  defp cess_unsupported_issues(_other_answer), do: []

  # A two-exit question is answered only by choosing an exit. Without this, a
  # bare confirmation on the cess target would mean "no cess applies" by
  # default — the accidental clearance this classification exists to prevent.
  defp answered?(%{"target" => "cess_not_evaluated|" <> _digest} = confirmation),
    do: get_in(confirmation, ["payload", "answer"]) in ~w(no_cess cess_applies)

  # Same rule for the completeness questions, and the same shape as cess: "yes"
  # and "no" both *answer* it — what "yes" uncovers is a separate blocking issue
  # that stands on its own. Leaving the question open as well would count one
  # answered question twice and tell a reviewer they still owe an answer they
  # have already given.
  #
  # "Unknown" does not settle it, because nobody has actually checked. That is a
  # legitimate answer to give and a legitimate reason to stop.
  defp answered?(%{"target" => target} = confirmation) when is_binary(target) do
    case String.split(target, "|") do
      [key, _scope] when key in @completeness_keys ->
        get_in(confirmation, ["payload", "answer"]) in ~w(no yes)

      _other ->
        true
    end
  end

  defp answered?(_confirmation), do: true

  defp cess_answer(effective, target) do
    effective
    |> Enum.filter(&(&1["verb"] == "confirm_issue" and &1["target"] == target))
    |> List.last()
    |> case do
      nil -> nil
      confirmation -> get_in(confirmation, ["payload", "answer"])
    end
  end

  # The cess question's resolution target, scoped to the invoice set it was asked
  # about. A bare code would let a confirmation recorded over eight invoices cover
  # a ninth that arrived later; hashing the reviewed set means a changed set yields
  # a different key, so the old confirmation stops matching on its own rather than
  # through an invalidation rule someone has to maintain. Callers read the target
  # off the issue, never recompute it.
  #
  # Identity is source ID *and* invoice number, not the ID alone: IDs are
  # positional (`..._inv_03`), so a re-extraction that replaces the third bill
  # with a different one reuses its ID, and hashing IDs alone would carry the old
  # answer onto a document nobody looked at.
  defp cess_target(invoices) do
    digest =
      invoices
      |> Enum.map(&"#{&1["id"]}|#{&1["invoice_number"]}")
      |> Enum.sort()
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "cess_not_evaluated|#{digest}"
  end

  defp challenge_issues(effective, active_invoices) do
    effective
    |> Enum.filter(&(&1["verb"] == "challenge_treatment"))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1["target"])
    |> Enum.reverse()
    |> Enum.flat_map(fn challenge ->
      source_id = get_in(challenge, ["payload", "source_id"])

      case Enum.find(active_invoices, &(&1["id"] == source_id)) do
        nil ->
          []

        invoice ->
          [
            %{
              "invoice" => invoice["invoice_number"],
              "source_id" => source_id,
              "code" => "treatment_challenged",
              "level" => Issues.level_for("treatment_challenged"),
              "message" =>
                "Reviewer challenged Nila's GSTR-1 treatment; confirm the current recomputed treatment or correct the source invoice.",
              "fields" => [],
              "target" => challenge["target"],
              "challenged_treatment" => challenge["payload"]
            }
          ]
      end
    end)
  end

  defp compliance_issues(invoices, compliance) do
    hsn_issues = if compliance[:directory], do: Validation.sales_issues(invoices), else: []

    statutory_issues =
      if compliance[:rate_directory], do: RateValidation.sales_issues(invoices), else: []

    history = compliance[:rate_history] || []
    summary_issues = Validation.summary_issues(invoices, history)
    history_issues = RateHistory.issues(invoices, history)
    hsn_issues ++ statutory_issues ++ summary_issues ++ history_issues
  end

  @doc """
  Stable resolution target for an issue. Invoice issues use pristine source ID,
  duplicate-number groups carry their own explicit target, and month issues use
  their code. Legacy number-based targets are translated only for a uniquely
  identified pristine source row during materialization.
  """
  def issue_key(%{"code" => "duplicate_invoice_number", "target" => target})
      when is_binary(target),
      do: target

  def issue_key(%{"code" => "treatment_challenged", "target" => target})
      when is_binary(target),
      do: target

  def issue_key(%{"source_id" => source_id, "code" => code}) when is_binary(source_id),
    do: "#{source_id}:#{code}"

  def issue_key(%{"invoice" => nil, "target" => target}) when is_binary(target), do: target
  def issue_key(%{"invoice" => nil, "code" => code}), do: code
  def issue_key(%{"invoice" => invoice, "code" => code}), do: "#{invoice}:#{code}"
  def issue_key(%{"code" => code}), do: code

  # One row per resolution target, because that is what a reviewer can answer.
  #
  # `issue_key/1` is deliberately coarser than a line — `source_id:code` — so an
  # invoice whose five lines carry the same unknown HSN raised five rows that all
  # posted the same target. Answering any one of them resolved all five and the
  # count fell by five: the reviewer was shown five checks where there was one,
  # and then told he had cleared work he never saw. Six generators concatenated
  # with no `uniq` made the same shape wherever a check runs per line, per page
  # or per source file rather than per invoice.
  #
  # Only gating issues collapse. An `info` row is a settled observation, not
  # work: the CGST and SGST rounding differences on one invoice share a key
  # precisely because neither is ever answered, and the modal anchors each to its
  # own evidence. Merging those would lose a fact and settle nothing.
  #
  # The survivor carries every message, because the line numbers are the part a
  # reviewer works from, and the union of `fields`, because that is what makes
  # each flagged value correctable.
  defp collapse_by_target(issues) do
    {gating, ungated} = Enum.split_with(issues, &Issues.gating?/1)
    grouped = Enum.group_by(gating, &issue_key/1)

    gating
    |> Enum.map(&issue_key/1)
    |> Enum.uniq()
    |> Enum.map(&merge_issues(grouped[&1]))
    |> Enum.concat(ungated)
  end

  defp merge_issues([issue]), do: issue

  defp merge_issues([first | _rest] = group) do
    first
    |> Map.put("message", group |> Enum.map(& &1["message"]) |> Enum.uniq() |> Enum.join("; "))
    |> Map.put("fields", group |> Enum.flat_map(&List.wrap(&1["fields"])) |> Enum.uniq())
    |> merge_lines(group)
  end

  defp merge_lines(issue, group) do
    case group
         |> Enum.flat_map(&List.wrap(&1["lines"] || &1["line"]))
         |> Enum.uniq()
         |> Enum.sort() do
      [] -> issue
      lines -> Map.put(issue, "lines", lines)
    end
  end

  # Severity first, then the kind of work, then the order the generators ran in.
  #
  # The list arrived in concatenation order, which put `blocking_issues` after
  # every per-invoice arithmetic check: a month-stopping blocker rendered below a
  # dozen routine tallies. Level decides first because a blocker is not more
  # work, it is a different verdict. Kind decides next so a reviewer works one
  # tool at a time rather than switching per row. The generator index breaks
  # ties, so the same month renders the same list every time.
  defp sort_by_severity(issues) do
    issues
    |> Enum.with_index()
    |> Enum.sort_by(fn {issue, index} ->
      {level_rank(Issues.level(issue)), kind_rank(Issues.resolution_kind(issue)), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp level_rank("blocking"), do: 0
  defp level_rank("required"), do: 1
  defp level_rank("advisory"), do: 2
  defp level_rank(_info), do: 3

  # Corrections first: a wrong number is the only kind that changes what gets
  # filed, and a decision taken over a figure about to be corrected is taken
  # twice. Confirmations last, because they attest to what the other two settle.
  # An issue that asks for no work at all sorts last within its level — every
  # `blocking` code is one, and there is nothing to do but read it.
  defp kind_rank(:correction), do: 0
  defp kind_rank(:decision), do: 1
  defp kind_rank(:confirmation), do: 2
  defp kind_rank(_no_work), do: 3

  @doc """
  True when nothing that gates approval remains open: every `blocking` or
  `required` issue has been answered, and `advisory`/`info` never gated.
  """
  def reviewable?(issues) do
    Enum.all?(issues, fn issue ->
      not blocking?(issue) and (issue["status"] == "resolved" or not Issues.gating?(issue))
    end)
  end

  @doc """
  Whether an issue can be answered by a human at all.

  Every other issue is a question about the numbers, and confirming it is a real
  answer: the reviewer looked, and the bill really does say that. A blocking
  issue is different in kind — it says the return has no table for this
  document, so `Gstr1.derive/2` will file it as something it is not. Confirming
  that changes nothing about what gets filed, so confirmation must not clear it.
  """
  def blocking?(issue), do: Issues.blocking?(issue)

  # Latest correction per (source, field) wins, and invoice-number corrections
  # apply last so all corrections continue to address pristine source identity.
  defp effective_corrections(corrections) do
    corrections
    |> Enum.reverse()
    |> Enum.uniq_by(fn c -> {c["target"], c["payload"]["field"]} end)
    |> Enum.reverse()
    |> Enum.sort_by(&(&1["payload"]["field"] == "invoice_number"))
  end

  defp correction_map(resolution) do
    %{
      "source_id" => resolution["target"],
      "field" => resolution["payload"]["field"],
      "value" => resolution["payload"]["to"]
    }
  end

  defp normalize_correction_targets(corrections, invoices) do
    ids = MapSet.new(invoices, & &1["id"])
    by_number = Enum.group_by(invoices, & &1["invoice_number"])

    Enum.map(corrections, fn correction ->
      target = correction["target"]

      cond do
        MapSet.member?(ids, target) ->
          correction

        match?([_], by_number[target]) ->
          Map.put(correction, "target", by_number[target] |> hd() |> Map.fetch!("id"))

        true ->
          correction
      end
    end)
  end

  defp apply_exclusions(invoices, exclusions) do
    by_id = Map.new(invoices, &{&1["id"], &1})

    candidates =
      exclusions
      |> Enum.reverse()
      |> Enum.uniq_by(&get_in(&1, ["payload", "excluded_source_id"]))
      |> Enum.reduce(%{}, fn resolution, acc ->
        excluded_id = get_in(resolution, ["payload", "excluded_source_id"])
        retained_id = get_in(resolution, ["payload", "retained_source_id"])
        excluded = by_id[excluded_id]
        retained = by_id[retained_id]

        if excluded && retained && excluded["id"] != retained["id"] &&
             present_number?(excluded["invoice_number"]) &&
             excluded["invoice_number"] == retained["invoice_number"] do
          Map.put(acc, excluded["id"], resolution)
        else
          acc
        end
      end)

    excluded_ids = Map.keys(candidates) |> MapSet.new()

    valid =
      Map.reject(candidates, fn {_source_id, resolution} ->
        MapSet.member?(excluded_ids, get_in(resolution, ["payload", "retained_source_id"]))
      end)

    marked =
      Enum.map(invoices, fn invoice ->
        case valid[invoice["id"]] do
          nil ->
            invoice

          resolution ->
            duplicate_copy =
              resolution["payload"]
              |> Map.take(["excluded_source_id", "retained_source_id", "reason", "outcome"])
              |> Map.put("excluded", true)

            Map.put(invoice, "duplicate_copy", duplicate_copy)
        end
      end)

    {copies, active} = Enum.split_with(marked, &Map.has_key?(&1, "duplicate_copy"))
    {marked, active, copies}
  end

  defp confirmed_issue_keys(confirmations, issues, pristine_invoices) do
    pristine_by_id = Map.new(pristine_invoices, &{&1["id"], &1})
    number_counts = Enum.frequencies_by(pristine_invoices, & &1["invoice_number"])

    Enum.reduce(confirmations, MapSet.new(), fn confirmation, confirmed ->
      target = confirmation["target"]

      case Enum.find(issues, fn issue ->
             issue_key(issue) == target or
               legacy_issue_target(issue, pristine_by_id, number_counts) == target
           end) do
        nil -> confirmed
        issue -> MapSet.put(confirmed, issue_key(issue))
      end
    end)
  end

  defp legacy_issue_target(%{"source_id" => source_id, "code" => code}, pristine, counts)
       when is_binary(source_id) do
    invoice_number = get_in(pristine, [source_id, "invoice_number"])
    if counts[invoice_number] == 1, do: "#{invoice_number}:#{code}"
  end

  # An issue that carries its own explicit target has no legacy alias — the cess
  # question's target is deliberately scoped to the invoice set it was asked
  # about, and honouring the bare code here would re-open the exact hole that
  # scoping closes.
  defp legacy_issue_target(%{"target" => target}, _pristine, _counts) when is_binary(target),
    do: nil

  defp legacy_issue_target(%{"invoice" => nil, "code" => code}, _pristine, _counts), do: code
  defp legacy_issue_target(_issue, _pristine, _counts), do: nil

  defp with_legacy_flag_aliases(flagged, invoices) do
    unique_numbers =
      invoices
      |> Enum.group_by(& &1["invoice_number"])
      |> Enum.filter(fn {_number, members} -> length(members) == 1 end)
      |> Map.new(fn {number, [invoice]} -> {invoice["id"], number} end)

    Enum.reduce(flagged, flagged, fn {source_id, field}, acc ->
      case unique_numbers[source_id] do
        nil -> acc
        invoice_number -> MapSet.put(acc, {invoice_number, field})
      end
    end)
  end

  defp present_number?(number), do: is_binary(number) and String.trim(number) != ""
end
