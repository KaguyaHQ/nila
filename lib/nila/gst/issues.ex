defmodule Nila.Gst.Issues do
  @moduledoc """
  The classification of every issue code a GST month can raise: how hard it
  gates outputs (`level`, stored on the issue) and what work answers it
  (`resolution_kind`, derived from the code and never stored).

  Two axes, because a blocker is a severity and a decision is a kind of work.

    * `blocking`  — Nila cannot generate the requested output from the available data.
      The underlying problem must be fixed; reviewer confirmation alone cannot clear it.
    * `required`  — a reviewer's action is needed before output. Gates.
    * `advisory`  — useful context; nothing is asserted to be wrong.
    * `info`      — Nila checked something unusual and settled it itself.

  `resolution_kind` is derived from the code rather than stored on each issue.

  Writers supply the issue's level. `normalize/1` preserves a recognized
  level and treats a missing or unrecognized level as `required`, so an issue
  we cannot rank still needs review.
  """

  @levels ~w(blocking required advisory info)

  # {level, resolution_kind}. Every code any GST surface can raise appears here;
  # a code missing from this table is a classification bug, not a default.
  @classification %{
    # Arithmetic and extraction checks on one invoice
    "missing_taxable_value" => {"blocking", :correction},
    "missing_tax_amount" => {"blocking", :correction},
    "line_arithmetic" => {"required", :correction},
    "cgst_sgst_unequal" => {"required", :correction},
    "lopsided_tax_split" => {"required", :correction},
    "printed_taxable_mismatch" => {"required", :decision},
    "printed_tax_mismatch" => {"required", :decision},
    "grand_total_mismatch" => {"required", :decision},
    "bucket_tax_mismatch" => {"required", :decision},
    "tax_split_mismatch" => {"required", :decision},
    "tax_treatment_uncertain" => {"required", :decision},
    "mixed_tax_heads" => {"required", :decision},
    "rounding_variance" => {"info", nil},
    "furniture_row_with_values" => {"required", :decision},
    "unreadable_invoice_date" => {"required", :correction},
    "invoice_period_mismatch" => {"blocking", :correction},
    "unreadable_amount" => {"required", :correction},
    "ungrounded_extracted_value" => {"required", :correction},
    "implausible_invoice_number" => {"required", :correction},
    "missing_invoice_number" => {"required", :correction},
    "invalid_document_type" => {"blocking", :correction},
    "document_type_conflict" => {"blocking", :correction},
    "zero_value_row" => {"required", :decision},
    "invalid_gstin" => {"required", :correction},
    "unknown_recipient_registration" => {"required", :correction},
    "recipient_registration_conflict" => {"required", :correction},
    "missing_place_of_supply" => {"required", :correction},
    "invalid_place_of_supply" => {"required", :correction},
    "unknown_document_status" => {"required", :correction},
    "unknown_supply_type" => {"required", :correction},
    "missing_tax_payment" => {"blocking", :correction},
    "special_supply_conflict" => {"blocking", :correction},
    "special_note_unsupported" => {"blocking", nil},
    "missing_original_sale_category" => {"required", :correction},
    "non_taxable_tax_conflict" => {"required", :correction},
    "sequence_gaps" => {"required", :confirmation},

    # HSN/SAC and rate compliance
    "missing_hsn_sac" => {"required", :correction},
    "missing_uom" => {"required", :correction},
    "incomplete_hsn_sac" => {"required", :correction},
    "invalid_hsn_sac" => {"required", :correction},
    "hsn_inferred_code" => {"required", :confirmation},
    "statutory_rate_mismatch" => {"required", :decision},
    "statutory_rate_review" => {"required", :decision},

    # The extraction ledger
    "pages_unaccounted" => {"required", :confirmation},
    "evidence_unavailable" => {"required", :confirmation},
    "sales_not_in_tally" => {"required", :confirmation},
    "sales_document_missing" => {"advisory", nil},
    "tally_document_mismatch" => {"required", :decision},
    "tally_export_failed" => {"blocking", nil},
    "cess_unsupported" => {"blocking", nil},

    # Treatments not yet supported by the Tally voucher writer.
    # GSTR-1 supports these treatments and does not emit these blockers.
    "export_supply_unsupported" => {"blocking", nil},
    "sez_supply_unsupported" => {"blocking", nil},
    "nil_rated_supply_unsupported" => {"blocking", nil},
    "exempt_supply_unsupported" => {"blocking", nil},
    "non_gst_supply_unsupported" => {"blocking", nil},
    "outward_reverse_charge_unsupported" => {"blocking", nil},

    # Document statuses restricted by both output paths
    "cancelled_document_unsupported" => {"blocking", nil},
    "amendment_document_unsupported" => {"blocking", nil},

    # Conflicting invoice identities
    "duplicate_invoice_number" => {"blocking", :decision}
  }

  @doc """
  Every code this module classifies.

  Exposed so a test can hold the engine's emitted codes against it: `level_for/1`
  falls back to `required` for an unknown code, which fails safe at runtime but
  would let an unclassified check ship silently.
  """
  def known_codes, do: Map.keys(@classification)

  @doc "The level this code is emitted at today. The single source for new checks."
  def level_for(code) do
    case @classification[code] do
      {level, _kind} -> level
      nil -> "required"
    end
  end

  @doc """
  The work that answers this issue: `:decision`, `:confirmation`, `:correction`,
  or `nil` when there is nothing for a reviewer to do.

  """
  def resolution_kind(%{"code" => code}), do: resolution_kind(code)

  def resolution_kind(code) when is_binary(code) do
    case @classification[code] do
      {_level, kind} -> kind
      nil -> nil
    end
  end

  @doc """
  The effective level of a stored issue.

  Recognized levels stand as recorded. Missing or unrecognized levels require
  review; the reader does not infer a level from the issue code.
  """
  def level(%{"code" => code, "level" => level}) when level in @levels and is_binary(code),
    do: level

  def level(%{"code" => code}) when is_binary(code), do: "required"

  @doc "The issue with its effective level written in. Read-time only."
  def normalize(%{"code" => _code} = issue), do: Map.put(issue, "level", level(issue))

  @doc "Normalizes the levels in a list of issues."
  def normalize_all(issues) when is_list(issues), do: Enum.map(issues, &normalize/1)

  @doc "True when this issue gates output: `blocking` or `required`."
  def gating?(issue), do: level(issue) in ~w(blocking required)

  @doc "True when this issue is context only and never gates output."
  def advisory?(issue), do: level(issue) == "advisory"

  @doc "True when reviewer confirmation cannot clear this issue."
  def blocking?(issue), do: level(issue) == "blocking"

  @doc """
  Counts the supplied issues by the work needed to resolve them.
  Callers select the relevant issues; this function does not filter their status.

  A gating issue with no kind is counted as `:blocked` rather than dropped. Most
  `blocking` codes ask for no work because the return lacks the capability; a
  blocking correction instead stays in the correction queue until the missing
  filing evidence is supplied.
  """
  def by_kind(issues) do
    empty = %{decision: 0, confirmation: 0, correction: 0, blocked: 0}

    Enum.reduce(issues, empty, fn issue, counts ->
      case {resolution_kind(issue), gating?(issue)} do
        {nil, false} -> counts
        {nil, true} -> Map.update!(counts, :blocked, &(&1 + 1))
        {kind, _gating} -> Map.update(counts, kind, 1, &(&1 + 1))
      end
    end)
  end
end
