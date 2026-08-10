defmodule Nila.Gst.Purchase.ItcSource do
  use Nila.Schema

  @kinds ~w(books gstr2b)

  schema "gst_itc_sources" do
    field :kind, :string
    field :source_ref, :string
    field :payload, :map

    belongs_to :client_month, Nila.Gst.Purchase.Month
    has_many :case_events, Nila.Gst.Purchase.ItcSourceCaseEvent, foreign_key: :source_id
    belongs_to :org, Nila.Orgs.Org

    timestamps(updated_at: false)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :source_ref, :payload])
    |> validate_required([:client_month_id, :org_id, :kind, :source_ref, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:client_month_id, :kind, :source_ref])
  end
end
