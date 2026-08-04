defmodule Nila.Gst.Issues do
  @moduledoc """
  The classification of every issue code a GST month can raise: how hard it
  gates approval (`level`, stored on the issue) and what work answers it
  (`resolution_kind`, derived from the code and never stored).

  Two axes, because a blocker is a severity and a decision is a kind of work.

    * `blocking`  — Nila cannot produce a valid filing from the available data,
      and reviewer confirmation alone cannot resolve it. Gates, unclearable.
    * `required`  — a reviewer's action is needed before approval. Gates.
    * `advisory`  — useful context; nothing is asserted to be wrong.
    * `info`      — Nila checked something unusual and settled it itself.

  `resolution_kind` is a lookup rather than a datum: storing it would freeze a
  labelling decision into signed history and let it drift from the code it
  describes. Deriving it means a wrong label is a one-line fix that
  retroactively corrects old snapshots too.

  `normalize/1` maps on read, never on write. Snapshots signed before levels
  were mandatory carry `nil` and `"warning"`; both resolve here by code, so an
  old `hsn_new_code` becomes `advisory` and an old `invalid_hsn_sac` becomes
  `required`. An unclassifiable level is treated as `required` — an issue we
  cannot rank withholds approval rather than silently permitting one.
  """

  @levels ~w(blocking required advisory info)

  # {level, resolution_kind}. Every code any GST surface can raise appears here;
  # a code missing from this table is a classification bug, not a default.
  @classification %{
    # Arithmetic and extraction checks on one invoice
    "line_arithmetic" => {"required", :correction},
    "cgst_sgst_unequal" => {"required", :correction},
    "lopsided_tax_split" => {"required", :correction},
    "printed_taxable_mismatch" => {"required", :decision},
    "printed_tax_mismatch" => {"required", :decision},
    "grand_total_mismatch" => {"required", :decision},
    "bucket_tax_mismatch" => {"required", :decision},
    "tax_split_mismatch" => {"required", :decision},
    "mixed_tax_heads" => {"required", :decision},
    "rounding_variance" => {"info", nil},
    "furniture_row_with_values" => {"required", :decision},
    "unreadable_invoice_date" => {"required", :correction},
    "unreadable_amount" => {"required", :correction},
    "implausible_invoice_number" => {"required", :correction},
    "missing_invoice_number" => {"required", :correction},
    "zero_value_row" => {"required", :decision},
    "invalid_gstin" => {"required", :correction},
    "sequence_gaps" => {"required", :confirmation},

    # HSN/SAC and rate compliance
    "missing_hsn_sac" => {"required", :correction},
    "incomplete_hsn_sac" => {"required", :correction},
    "invalid_hsn_sac" => {"required", :correction},
    "hsn_multiple_rates" => {"required", :decision},
    "hsn_inferred_code" => {"required", :confirmation},
    "hsn_new_code" => {"advisory", nil},
    "statutory_rate_mismatch" => {"required", :decision},
    "statutory_rate_review" => {"required", :decision},
    "rate_history_conflict" => {"required", :decision},

    # The extraction ledger
    "pages_unaccounted" => {"required", :confirmation},
    "evidence_unavailable" => {"required", :confirmation},
    "cess_unsupported" => {"blocking", nil},

    # Documents this return has no table for
    "credit_note_unsupported" => {"blocking", nil},
    "debit_note_unsupported" => {"blocking", nil},
    "export_supply_unsupported" => {"blocking", nil},
    "outward_reverse_charge_unsupported" => {"blocking", nil},
    "b2c_supply_unsupported" => {"blocking", nil},
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

  There is no `:collection` on this side. It was advertised here, and a noun was
  reserved for it downstream, but nothing in `@classification` ever mapped to it
  — so a sales issue could never be "waiting on the client", and the promise
  read as a feature to anyone reading the code. The purchase track has a real
  collection queue in the purchase review surface; if the sales side needs
  one, it gets built there and mapped here, not declared in a docstring.
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

  A level this module knows stands as recorded. A snapshot signed before levels
  were mandatory carries `nil` or `"warning"`, and both resolve by code — the
  level that code would carry today. Anything else is a value from a future or
  broken writer: it resolves to `required`, so an issue nobody can rank
  withholds approval rather than silently permitting one.

  Emits `[:nila, :gst, :issues, :legacy_level]` whenever it has to map.
  """
  def level(%{"code" => code, "level" => level}) when level in @levels and is_binary(code),
    do: level

  def level(%{"code" => code} = issue) when is_binary(code) do
    stored = issue["level"]
    mapped = if stored in [nil, "warning"], do: level_for(code), else: "required"

    :telemetry.execute(
      [:nila, :gst, :issues, :legacy_level],
      %{count: 1},
      %{code: code, stored: stored, mapped: mapped}
    )

    mapped
  end

  @doc "The issue with its effective level written in. Read-time only."
  def normalize(%{"code" => _code} = issue), do: Map.put(issue, "level", level(issue))

  @doc "Normalizes a list of issues, including legacy snapshot lists."
  def normalize_all(issues) when is_list(issues), do: Enum.map(issues, &normalize/1)

  @doc "True when this issue withholds approval: `blocking` or `required`."
  def gating?(issue), do: level(issue) in ~w(blocking required)

  @doc "True when this issue is context only and never gates approval."
  def advisory?(issue), do: level(issue) == "advisory"

  @doc "True when reviewer confirmation cannot clear this issue."
  def blocking?(issue), do: level(issue) == "blocking"

  @doc """
  Counts of the work open across these issues, by kind.

  A gating issue with no kind is counted as `:blocked` rather than dropped. Every
  `blocking` code asks for no work — that is what makes it blocking — but it
  still withholds the filing, and a count that gates while staying invisible is
  the exact defect this classification exists to remove.
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
