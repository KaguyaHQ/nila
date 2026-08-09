defmodule Nila.Gst.Purchase.ItcCase do
  use Nila.Schema

  @identity_states ~w(provisional confirmed ambiguous merged)

  schema "gst_itc_cases" do
    field :supplier_gstin, :string
    field :document_type, :string, default: "invoice"
    field :invoice_number, :string
    field :normalized_invoice_number, :string
    field :supplier_fy_start_year, :integer
    field :match_key, :string
    field :identity_state, :string, default: "provisional"

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :merged_into_case, __MODULE__

    has_many :sources, Nila.Gst.Purchase.ItcSource, foreign_key: :case_id
    has_many :events, Nila.Gst.Purchase.ItcCaseEvent, foreign_key: :case_id
    has_many :allocations, Nila.Gst.Purchase.ItcAllocation, foreign_key: :case_id

    timestamps()
  end

  def changeset(itc_case, attrs) do
    itc_case
    |> cast(attrs, [
      :supplier_gstin,
      :document_type,
      :invoice_number,
      :normalized_invoice_number,
      :supplier_fy_start_year,
      :match_key,
      :identity_state,
      :merged_into_case_id
    ])
    |> validate_required([:org_id, :client_id, :document_type, :identity_state])
    |> validate_inclusion(:identity_state, @identity_states)
  end
end
