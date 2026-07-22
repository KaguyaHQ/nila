defmodule Nila.Gst.Purchase.Resolution do
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
    * `accept_unmatched` — keep an unmatched books bill with an audited reason:
      await a future 2B or do not claim it this month.
    * `dismiss_2b`    — remove a 2B-only row confirmed as not belonging to the client.
    * `reopen`        — undo: discards prior decisions for its books row, 2B
      reference, or ITC block target so the exception re-opens for review.
    * `block_itc` / `allow_itc` — confirm or override Nila's recommendation to
      block a credit (personal/17(5), duplicate, state mismatch). Targets a
      `block_id` in `payload["block_id"]`, not a books row — it adjusts the
      claimable ITC, not the recon buckets.
  """
  use Nila.Schema

  @verbs ~w(confirm_pair reject_pair correct_field accept_unmatched dismiss_2b reopen block_itc allow_itc)

  def verbs, do: @verbs

  schema "gst_resolutions" do
    field :verb, :string
    field :books_id, :string
    field :gstr2b_ref, :string
    field :payload, :map, default: %{}

    belongs_to :client_month, Nila.Gst.Purchase.Month
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
