defmodule Nila.Gst.Sales.Workings do
  @moduledoc """
  Layers human resolutions over a worked sales month to produce the *effective*
  outward month: corrected invoices, re-validated issues, and the re-derived
  portal-shaped GSTR-1. The sales mirror of `Nila.Gst.Purchase.Workings`.

  The stored `invoices`/`issues`/`derived_gstr1` are machine truth and are
  never mutated. Corrections go through the real `CorrectionPolicy.apply_corrections/3`
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

  alias Nila.Gst.Sales.Gstr1.Documents
  alias Nila.Gst.Sales.Review.CorrectionPolicy
  alias Nila.Gst.Issues
  alias Nila.Gst.Replay
  alias Nila.Gst.Sales.{Gstr1, Invoice}
  alias Nila.Gst.Sales.Gstr1.Readiness, as: Gstr1Readiness
  alias Nila.Gst.Sales.Invoice.Readiness, as: InvoiceReadiness

  @doc """
  Applies resolutions (append-only, oldest first) to a sales month's invoices,
  returning the effective month. `resolutions` are plain maps with string keys
  mirroring `Nila.Gst.Sales.Review.Resolution` (`"verb"`, `"target"`, `"payload"`).
  `header` is the `Gstr1.derive/2` second argument (production header).

  Returns explicit `source_invoices`, `active_invoices`, and
  `duplicate_copies` projections. `invoices` remains the effective source-row
  projection for compatibility and audit output; only `active_invoices` feed
  validation and derivation. Issues carry `"status"` of `"open" | "resolved"`.
  `decisions` is the effective `%{target => verb}` map, `corrections` the
  effective correction resolutions in apply order, and `flagged` the
  `CorrectionPolicy.flagged_fields/2` set on pristine source identity.
  """
  def materialize(invoices, resolutions, header, document_issues \\ [], opts \\ [])

  def materialize(invoices, resolutions, header, document_issues, %{} = compliance) do
    materialize(invoices, resolutions, header, document_issues, compliance: compliance)
  end

  def materialize(invoices, resolutions, header, document_issues, opts) when is_list(opts) do
    compliance = Keyword.get(opts, :compliance, %{})

    period =
      case header["fp"] do
        <<month::binary-size(2), year::binary-size(4)>> -> year <> "-" <> month
        _ -> nil
      end

    pristine_source_invoices =
      invoices
      |> Enum.map(fn invoice ->
        # This report supplies GSTIN, not seller name. Older imports copied the
        # client label here; it must never be compared as a printed source fact.
        if invoice["return_report_section"],
          do: Map.put(invoice, "seller_name", nil),
          else: invoice
      end)
      |> ensure_source_ids(Keyword.get(opts, :source_namespace, "legacy"))
      |> Enum.map(&Nila.Gst.Sales.TaxDetermination.reset/1)
      |> Enum.map(&Invoice.resolve_line_amounts/1)
      |> InvoiceReadiness.annotate(compliance)

    effective = Replay.drop_reopened(resolutions, "target")
    decisions = Replay.decisions(resolutions, "target")

    corrections =
      effective
      |> Enum.filter(&(&1["verb"] == "correct_field"))
      |> effective_corrections()

    correction_issues =
      pristine_source_invoices
      |> InvoiceReadiness.issues()
      |> Enum.concat(Gstr1Readiness.issues(pristine_source_invoices))
      |> Enum.concat(Gstr1Readiness.period_issues(pristine_source_invoices, period))
      |> Enum.concat(Nila.Gst.Sales.ReturnSources.invoice_checks(pristine_source_invoices))

    source_flagged = CorrectionPolicy.flagged_fields(pristine_source_invoices, correction_issues)

    {legit, silent_errors} =
      corrections
      |> Enum.map(&correction_map/1)
      |> Enum.split_with(
        &CorrectionPolicy.correction_allowed?(source_flagged, &1["source_id"], &1["field"])
      )

    {corrected, _applied, [], _flags} =
      CorrectionPolicy.apply_corrections(pristine_source_invoices, legit, source_flagged)

    corrected =
      corrected
      |> Enum.map(&Invoice.resolve_line_amounts/1)
      |> InvoiceReadiness.annotate(compliance)

    exclusions = Enum.filter(effective, &(&1["verb"] == "exclude_duplicate_copy"))
    {source_invoices, active_invoices, duplicate_copies} = apply_exclusions(corrected, exclusions)

    {printed_invoices, printed_active_invoices, _printed_copies} =
      apply_exclusions(pristine_source_invoices, exclusions)

    reports = Keyword.get(opts, :return_reports, [])

    # Re-evaluate the evidence after corrections and duplicate exclusions. A
    # previously reconciled population cannot authorize a changed population.
    active_invoices =
      active_invoices
      |> Nila.Gst.Sales.TaxDetermination.prepare(reports)
      |> InvoiceReadiness.annotate(compliance)

    valued = Map.new(active_invoices, &{&1["id"], &1})
    source_invoices = Enum.map(source_invoices, &Map.get(valued, &1["id"], &1))

    {projection, report_issues, supplied_rows} =
      Nila.Gst.Sales.ReturnSources.apply(
        Gstr1.project(active_invoices, header),
        active_invoices,
        reports
      )

    raw_issues =
      active_invoices
      |> InvoiceReadiness.issues()
      |> Enum.concat(Gstr1Readiness.issues(active_invoices))
      |> Enum.concat(
        Documents.issues(Enum.reject(active_invoices, & &1["return_report_section"]))
      )
      |> Enum.concat(Gstr1Readiness.period_issues(active_invoices, period))
      |> Enum.concat(document_issues)
      |> Nila.Gst.Sales.ReturnSources.invoice_issues(active_invoices, reports)
      |> Enum.concat(report_issues)
      |> Enum.concat(Nila.Gst.Sales.ReturnSources.invoice_checks(active_invoices))
      |> Issues.normalize_all()
      |> collapse_by_target()
      |> Enum.map(
        &Nila.Gst.Sales.Review.MonthChecks.bind(
          &1,
          active_invoices,
          Keyword.get(opts, :packet_basis, [])
        )
      )

    confirmations =
      effective
      |> Replay.latest("target")
      |> Map.values()
      |> Enum.filter(&(&1["verb"] == "confirm_issue"))

    confirmed = Map.new(confirmations, &{&1["target"], &1})

    issues =
      raw_issues
      |> Enum.map(fn issue ->
        status =
          if not blocking?(issue) and
               Nila.Gst.Sales.Review.MonthChecks.confirmed?(issue, confirmed[issue_key(issue)]),
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
      derived: projection.derived,
      contributions: projection.contributions,
      supplied_rows: supplied_rows,
      return_reports: reports,
      decisions: decisions,
      corrections: corrections,
      flagged: source_flagged,
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

  @doc """
  Stable resolution target for an issue. Invoice issues use pristine source ID,
  duplicate-number groups carry their own explicit target, and month issues use
  their code. Saved decisions match these targets exactly.
  """
  def issue_key(%{"code" => "duplicate_invoice_number", "target" => target})
      when is_binary(target),
      do: target

  def issue_key(%{"code" => code, "target" => target})
      when code in ~w(seller_gst_registration_review buyer_gst_registration_review seller_gst_name_review buyer_gst_name_review),
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
  True when the working has no open blocking or required issues.
  Advisory and informational findings remain visible without holding up the work.
  """
  def reviewable?(issues) do
    Enum.all?(issues, fn issue ->
      not blocking?(issue) and (issue["status"] == "resolved" or not Issues.gating?(issue))
    end)
  end

  @doc "Whether a sales working contains source transactions or supplied return rows."
  def has_return_data?(projection) do
    Map.get(projection, :active_invoices, []) != [] or
      Map.get(projection, :supplied_rows, []) != []
  end

  @doc """
  Whether reviewer confirmation alone cannot clear this issue.

  A blocker can represent an unsupported output treatment, missing evidence,
  or conflicting invoice identities. The underlying problem must be resolved
  before generating the affected output.
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

  defp present_number?(number), do: is_binary(number) and String.trim(number) != ""
end
