defmodule Nila.Gst.Purchase.ItcCaseEvent do
  use Nila.Schema

  @event_types ~w(
    documents_requested
    client_holds_document
    document_not_held
    excluded_not_ours
    reopened
    not_claiming_itc
    claim_reopened
    case_merged
    case_merge_reversed
  )

  def event_types, do: @event_types

  schema "gst_itc_case_events" do
    field :event_type, :string
    field :payload, :map, default: %{}

    belongs_to :itc_case, Nila.Gst.Purchase.ItcCase, foreign_key: :case_id
    belongs_to :effective_client_month, Nila.Gst.Purchase.Month
    belongs_to :org, Nila.Orgs.Org
    belongs_to :decided_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :payload])
    |> validate_required([:case_id, :effective_client_month_id, :org_id, :event_type])
    |> validate_inclusion(:event_type, @event_types)
  end
end
