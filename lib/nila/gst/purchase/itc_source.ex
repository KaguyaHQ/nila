defmodule Nila.Gst.Purchase.ItcSource do
  use Nila.Schema

  @kinds ~w(books gstr2b)

  schema "gst_itc_sources" do
    field :kind, :string
    field :source_ref, :string
    field :payload, :map

    belongs_to :itc_case, Nila.Gst.Purchase.ItcCase, foreign_key: :case_id
    belongs_to :client_month, Nila.Gst.Purchase.Month
    belongs_to :org, Nila.Orgs.Org

    timestamps(updated_at: false)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :source_ref, :payload, :case_id])
    |> validate_required([:case_id, :client_month_id, :org_id, :kind, :source_ref, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:client_month_id, :kind, :source_ref])
  end
end
