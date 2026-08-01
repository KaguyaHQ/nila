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
  def materialize(invoices, resolutions, header, document_issues \\ [], opts \\ []) do
    pristine_source_invoices =
      ensure_source_ids(invoices, Keyword.get(opts, :source_namespace, "legacy"))

    effective = Replay.drop_reopened(resolutions, "target")
    decisions = Replay.decisions(resolutions, "target")

    corrections =
      effective
      |> Enum.filter(&(&1["verb"] == "correct_field"))
      |> normalize_correction_targets(pristine_source_invoices)
      |> effective_corrections()

    correction_issues =
      Gstr1.validation_issues(pristine_source_invoices) ++
        Gstr1.duplicate_number_issues(pristine_source_invoices)

    source_flagged = Gstr1.flagged_fields(pristine_source_invoices, correction_issues)

    {legit, silent_errors} =
      corrections
      |> Enum.map(&correction_map/1)
      |> Enum.split_with(&Gstr1.correction_allowed?(source_flagged, &1["source_id"], &1["field"]))

    {corrected, _applied, [], _flags} =
      Gstr1.apply_corrections(pristine_source_invoices, legit, source_flagged)

    exclusions = Enum.filter(effective, &(&1["verb"] == "exclude_duplicate_copy"))
    {source_invoices, active_invoices, duplicate_copies} = apply_exclusions(corrected, exclusions)

    raw_issues =
      active_invoices
      |> Gstr1.validation_issues()
      |> Enum.concat(Gstr1.blocking_issues(active_invoices))
      |> Enum.concat(document_issues)

    confirmations = Enum.filter(effective, &(&1["verb"] == "confirm_issue"))

    confirmed_keys =
      confirmed_issue_keys(confirmations, raw_issues, pristine_source_invoices)

    issues =
      Enum.map(raw_issues, fn issue ->
        status =
          if not blocking?(issue) and MapSet.member?(confirmed_keys, issue_key(issue)),
            do: "resolved",
            else: "open"

        Map.put(issue, "status", status)
      end)

    %{
      invoices: source_invoices,
      source_invoices: source_invoices,
      active_invoices: active_invoices,
      duplicate_copies: duplicate_copies,
      issues: issues,
      derived: Gstr1.derive(active_invoices, header),
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

  @doc """
  Stable resolution target for an issue. Invoice issues use pristine source ID,
  duplicate-number groups carry their own explicit target, and month issues use
  their code. Legacy number-based targets are translated only for a uniquely
  identified pristine source row during materialization.
  """
  def issue_key(%{"code" => "duplicate_invoice_number", "target" => target})
      when is_binary(target),
      do: target

  def issue_key(%{"source_id" => source_id, "code" => code}) when is_binary(source_id),
    do: "#{source_id}:#{code}"

  def issue_key(%{"invoice" => nil, "code" => code}), do: code
  def issue_key(%{"invoice" => invoice, "code" => code}), do: "#{invoice}:#{code}"

  @doc "True when no effective issue above `info` level remains open."
  def reviewable?(issues) do
    Enum.all?(issues, fn issue ->
      not blocking?(issue) and (issue["status"] == "resolved" or issue["level"] == "info")
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
  def blocking?(issue), do: issue["level"] == "blocking"

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
