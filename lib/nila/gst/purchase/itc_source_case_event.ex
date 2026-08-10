defmodule Nila.Gst.Purchase.ItcSourceCaseEvent do
  use Nila.Schema

  @actions ~w(linked unlinked)

  schema "gst_itc_source_case_events" do
    field :action, :string
    field :reason, :string

    belongs_to :source, Nila.Gst.Purchase.ItcSource
    belongs_to :itc_case, Nila.Gst.Purchase.ItcCase, foreign_key: :case_id
    belongs_to :effective_client_month, Nila.Gst.Purchase.Month
    belongs_to :org, Nila.Orgs.Org
    belongs_to :decided_by, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:action, :reason])
    |> validate_required([
      :source_id,
      :case_id,
      :effective_client_month_id,
      :org_id,
      :action,
      :reason
    ])
    |> validate_inclusion(:action, @actions)
  end
end
