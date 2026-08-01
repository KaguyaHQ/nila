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

  Returns `%{invoices, issues, derived, decisions, corrections, flagged,
  silent_errors}` where `issues` carry a `"status"` of `"open" | "resolved"`,
  `decisions` is the effective `%{target => verb}` map, `corrections` the
  effective correction resolutions in apply order, and `flagged` the
  `Gstr1.flagged_fields/2` set on the pristine invoices (what a human may
  legitimately correct).
  """
  def materialize(invoices, resolutions, header, document_issues \\ []) do
    effective = Replay.drop_reopened(resolutions, "target")
    decisions = Replay.decisions(resolutions, "target")

    corrections = Enum.filter(effective, &(&1["verb"] == "correct_field"))
    confirmations = Enum.filter(effective, &(&1["verb"] == "confirm_issue"))

    corrections = effective_corrections(corrections)
    flagged = Gstr1.flagged_fields(invoices, Gstr1.validation_issues(invoices))

    {legit, silent_errors} =
      corrections
      |> Enum.map(&correction_map/1)
      |> Enum.split_with(&Gstr1.correction_allowed?(flagged, &1["invoice"], &1["field"]))

    {invoices, _applied, [], _flags} = Gstr1.apply_corrections(invoices, legit, flagged)

    confirmed_keys = MapSet.new(confirmations, & &1["target"])

    issues =
      invoices
      |> Gstr1.validation_issues()
      |> Enum.concat(Gstr1.blocking_issues(invoices))
      |> Enum.concat(document_issues)
      |> Enum.map(fn issue ->
        status = if MapSet.member?(confirmed_keys, issue_key(issue)), do: "resolved", else: "open"
        Map.put(issue, "status", status)
      end)

    %{
      invoices: invoices,
      issues: issues,
      derived: Gstr1.derive(invoices, header),
      decisions: decisions,
      corrections: corrections,
      flagged: flagged,
      silent_errors: silent_errors
    }
  end

  @doc """
  The resolution target for an issue: `"invoice_number:code"`, or just the
  code for month-level issues (sequence gaps have no invoice). Keys use the
  invoice's *current* number, so renumbering an invoice orphans that
  invoice's earlier confirmations — its issues re-open under the new key and
  must be re-confirmed. Accepted: a renumbered invoice is a different claim
  against the scan, and re-review is the safe default.
  """
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

  # Latest correction per (invoice, field) wins, and invoice-number corrections
  # apply last: `Gstr1.apply_corrections/3` matches invoices by their *current*
  # number while targets always carry the pristine number, so renumbering an
  # invoice must not run before that invoice's other corrections.
  defp effective_corrections(corrections) do
    corrections
    |> Enum.reverse()
    |> Enum.uniq_by(fn c -> {c["target"], c["payload"]["field"]} end)
    |> Enum.reverse()
    |> Enum.sort_by(&(&1["payload"]["field"] == "invoice_number"))
  end

  defp correction_map(resolution) do
    %{
      "invoice" => resolution["target"],
      "field" => resolution["payload"]["field"],
      "value" => resolution["payload"]["to"]
    }
  end
end
