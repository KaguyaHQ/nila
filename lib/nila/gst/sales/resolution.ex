defmodule Nila.Gst.Sales.Resolution do
  @moduledoc """
  One human decision about one sales-month validation issue, stored
  append-only: a resolution is an *event*, never mutated. Reversing a decision
  is a new event; the latest event per target wins. The outward mirror of
  `Nila.Gst.Purchase.Resolution` — sales exceptions are validation issues on extracted
  invoices, not 2B pair-matching, so the verbs and target differ.

  `target` is the invoice number for `correct_field`, or the issue key
  (`SalesWorkings.issue_key/1`) for issue confirmations.

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
    * `reopen`        — undo: discards this target's prior decisions so it
      returns to the engine's default.
  """
  use Nila.Schema

  @verbs ~w(correct_field confirm_issue accept_difference reopen)

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
  end
end
