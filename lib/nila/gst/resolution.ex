defmodule Nila.Gst.Resolution do
  @moduledoc """
  One human decision about one reconciliation exception, stored append-only:
  a resolution is an *event*, never mutated. Reversing a decision is a new
  event; the latest event per target wins. This is both the audit trail and
  the raw correction data a later memory abstraction will learn from — so the
  payload captures the full decision context (both candidates, the field diff),
  not just the outcome.

  Verbs (for `invoice_number_mismatch`; other exception types add their own):

    * `confirm_pair`  — books_id and gstr2b_ref are the same bill; force a match.
    * `reject_pair`   — books_id and gstr2b_ref are NOT the same bill; never
      re-suggest that pairing.
    * `correct_field` — the extractor misread a books field; payload carries
      `{"field", "from", "to"}`. Re-reconciliation may then match cleanly.
    * `reopen`        — undo: discards this books row's prior decisions so it
      returns to the engine's default (the exception re-opens for review).
  """
  use Nila.Schema

  @verbs ~w(confirm_pair reject_pair correct_field reopen)

  def verbs, do: @verbs

  schema "gst_resolutions" do
    field :verb, :string
    field :books_id, :string
    field :gstr2b_ref, :string
    field :payload, :map, default: %{}

    belongs_to :client_month, Nila.Gst.ClientMonth
    belongs_to :org, Nila.Orgs.Org
    belongs_to :decided_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(resolution, attrs) do
    resolution
    |> cast(attrs, [:verb, :books_id, :gstr2b_ref, :payload])
    |> validate_required([:client_month_id, :org_id, :verb])
    |> validate_inclusion(:verb, @verbs)
  end
end
