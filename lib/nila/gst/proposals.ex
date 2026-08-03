defmodule Nila.Gst.Proposals do
  @moduledoc """
  What Nila would do about an issue, and what that costs.

  Cross-track by nature: a proposal is a stance on an exception, and both the
  sales register and the purchase reconciliation raise those.

  Every exception surface until now only *asked*. For a product whose principle
  is propose-then-confirm, that is the wrong half of the loop: a reviewer who is
  shown a problem and no recommendation is doing the whole job themselves.

  A proposal has three parts and never two:

    * `action`   — what the button does, in the reviewer's language.
    * `basis`    — why Nila thinks so, stated as an *observation* it made, never
      as an inference about someone else's behaviour.
    * `effect`   — what it changes in the figures that actually reach the portal,
      read out of `derive/2` rather than predicted alongside it.

  ## `nil` is a legitimate return

  No proposal is better than a weak one. The rule for shipping a treatment here:
  Nila must be able to state the basis as something it *observed*. If the basis
  would be a guess about what a supplier did, or a choice that is the reviewer's
  entire job, this returns `nil` and the surface renders the question alone.

  Deliberately absent, with the reason:

    * `sequence_gaps` — a bounded gap does not imply cancellation. It equally
      implies an omitted upload, a second series, or reserved-but-unissued
      numbers. Any honest proposal here is a *question* ("were 46–48 cancelled
      or omitted?"), not a treatment.
    * `hsn_inferred_code` — Nila inferred the code; it cannot also vouch for it.
    * `hsn_multiple_rates`, `statutory_rate_*`, `rate_history_conflict` — the
      basis would be a claim about what the item legally is.
    * `mixed_tax_heads`, `tax_split_mismatch` — which head is correct depends on
      where the supply happened, which is the reviewer's call. Nila can only
      observe that the document contradicts itself.
    * value mismatches against 2B — a difference can mean bad extraction, bad
      supplier reporting, a wrong candidate match, an unlinked credit note or
      mismapped heads. Recommending "take the 2B figure" because the engine
      already does is not a basis; it may only mean the current default is too
      blunt.

  ## Freezing

  A proposal is derived live, so it always follows current evidence and current
  rules. But the moment a reviewer acts on one, what they were shown becomes
  part of the record: `freeze/1` produces the snapshot stored in the resolution
  payload, so a rule change in October cannot rewrite what August's audit screen
  claims Nila advised. The frozen copy never feeds the return — it is evidence
  of what the human was told, nothing more.
  """

  @rule_version "2026-08-03"

  @arithmetic_codes ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

  @doc """
  Nila's proposal for `issue`, or `nil` when it has no basis to offer one.

  `values` is `Values.for_invoice/2` for the invoice the issue belongs to, and
  `checks` is `Gstr1.invoice_checks/1` for the same invoice — the basis claims
  the lines check out, so it has to read the same judge that decides whether
  they do.
  """
  def for_issue(issue, values \\ nil, checks \\ [])

  def for_issue(%{"code" => code}, values, checks) when code in @arithmetic_codes do
    with %{} <- values,
         %{} = filed <- values.filed,
         true <- lines_self_consistent?(checks) do
      %{
        id: "#{code}|use_extracted_lines",
        rule_version: @rule_version,
        code: code,
        decision: "use_extracted_lines",
        action: "Accept the extracted lines",
        # An observation about this document, not a judgement about the client's
        # bookkeeping: every line's own arithmetic checks out and only the
        # footer disagrees.
        basis: basis(code),
        effect: %{
          taxable: filed.taxable,
          tax: filed.tax,
          igst: filed.igst,
          cgst: filed.cgst,
          sgst: filed.sgst
        }
      }
    else
      _no_basis -> nil
    end
  end

  def for_issue(_issue, _values, _checks), do: nil

  @doc """
  The proposal for a 2B supply with no bill on file.

  Separate from `for_issue/2` because it is not an invoice issue — there is no
  document to open, and the treatment is a request rather than a decision about
  what to file.
  """
  def for_missing_bill(count, tax_paise) when count > 0 do
    %{
      id: "gstr2b_no_bill|request",
      rule_version: @rule_version,
      code: "gstr2b_no_bill",
      decision: "request_from_client",
      action: "Request the #{count} missing #{noun(count, "bill")} from the client",
      basis:
        "The portal reported #{count} #{noun(count, "supply")} the books have no document for.",
      effect: %{tax_paise: tax_paise}
    }
  end

  def for_missing_bill(_count, _tax_paise), do: nil

  @doc """
  The evidentiary snapshot stored in a resolution payload.

  Carries what the reviewer was shown, not what the engine would say today.
  """
  def freeze(nil), do: nil

  def freeze(proposal) do
    %{
      "proposal_id" => proposal.id,
      "rule_version" => proposal.rule_version,
      "code" => proposal.code,
      "decision" => proposal.decision,
      "action" => proposal.action,
      "basis" => proposal.basis,
      "effect" => stringify(proposal.effect),
      "shown_at" => DateTime.utc_now()
    }
  end

  # "Only the footer disagrees" is a claim about the lines, so it is read off
  # the same checks the modal renders ticks from. A bill with a failing line
  # *and* a failing total has no such basis — the reviewer is owed the question,
  # not a recommendation resting on a false premise.
  @line_codes ~w(line_arithmetic cgst_sgst_unequal)

  defp lines_self_consistent?(checks) do
    Enum.all?(checks, fn check ->
      check["code"] not in @line_codes or check["passed"]
    end)
  end

  defp basis("printed_taxable_mismatch"),
    do: "Every line's taxable value reads cleanly; only the printed total disagrees."

  defp basis("printed_tax_mismatch"),
    do:
      "Every line's tax multiplies out from its own taxable value and rate; only the printed total disagrees."

  defp basis("grand_total_mismatch"),
    do: "Every line's arithmetic checks out; only the printed bill total disagrees."

  defp noun(1, "bill"), do: "bill"
  defp noun(_n, "bill"), do: "bills"
  defp noun(1, "supply"), do: "supply"
  defp noun(_n, "supply"), do: "supplies"

  defp stringify(effect), do: Map.new(effect, fn {k, v} -> {to_string(k), v} end)
end
