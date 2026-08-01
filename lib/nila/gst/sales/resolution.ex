defmodule Nila.Gst.Sales.Resolution do
  @moduledoc """
  One human decision about one sales-month validation issue, stored
  append-only: a resolution is an *event*, never mutated. Reversing a decision
  is a new event; the latest event per target wins. The outward mirror of
  `Nila.Gst.Purchase.Resolution` — sales exceptions are validation issues on extracted
  invoices, not 2B pair-matching, so the verbs and target differ.

  `target` is the pristine source ID for `correct_field` and duplicate-copy
  exclusion, or the issue key (`SalesWorkings.issue_key/1`) for confirmations.
  Legacy invoice-number targets remain replayable only when they identify one
  source row.

  Verbs:

    * `correct_field` — the extractor misread an invoice field; payload carries
      `{"field", "from", "to"}`. Only flagged fields are legitimately
      correctable (`Gstr1.apply_corrections/3` enforces the silent-error
      discipline).
    * `confirm_issue` — the human reviewed the issue against the scan and the
      extraction stands: a sequence gap is a real cancellation, a printed-total
      mismatch is the paper's arithmetic error, a furniture row is genuine.
    * `accept_difference` — the filed return disagrees with the derived one on
      this field and ours is right; target is the `Nila.Eval.Gstr1Diff` row key
      (`"scope|key|field"`), payload optionally carries the reviewer's reason.
      The AUDITOR verdict as a product verb: the confession sheet on rebuilt
      months rides on these rows.
    * `exclude_duplicate_copy` — excludes one confirmed duplicate source copy;
      its namespaced target keeps undo separate from field corrections, and the
      payload records both source IDs, the reason, and the outcome.
    * `reopen`        — undo: discards this target's prior decisions so it
      returns to the engine's default.
  """
  use Nila.Schema

  @verbs ~w(correct_field confirm_issue accept_difference exclude_duplicate_copy reopen)

  def verbs, do: @verbs

  schema "sales_resolutions" do
    field :verb, :string
    field :target, :string
    field :payload, :map, default: %{}

    belongs_to :sales_month, Nila.Gst.Sales.Month
    belongs_to :org, Nila.Orgs.Org
    belongs_to :decided_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(resolution, attrs) do
    resolution
    |> cast(attrs, [:verb, :target, :payload])
    |> validate_required([:sales_month_id, :org_id, :verb, :target])
    |> validate_inclusion(:verb, @verbs)
    |> validate_duplicate_copy_payload()
  end

  defp validate_duplicate_copy_payload(changeset) do
    if get_field(changeset, :verb) == "exclude_duplicate_copy" do
      payload = get_field(changeset, :payload) || %{}

      if Enum.all?(
           ~w(excluded_source_id retained_source_id reason outcome),
           &present?(payload[&1])
         ) and
           payload["outcome"] == "same_invoice_uploaded_twice" and
           String.starts_with?(get_field(changeset, :target) || "", "duplicate_copy|") do
        changeset
      else
        add_error(
          changeset,
          :payload,
          "must record both source IDs and the same-invoice duplicate outcome"
        )
      end
    else
      changeset
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
