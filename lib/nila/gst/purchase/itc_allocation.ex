defmodule Nila.Gst.Purchase.ItcAllocation do
  use Nila.Schema

  schema "gst_itc_allocations" do
    field :kind, :string, default: "original_claim"
    field :tax_heads, :map
    field :tax_paise, :integer
    field :filed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :itc_case, Nila.Gst.Purchase.ItcCase, foreign_key: :case_id
    belongs_to :client_month, Nila.Gst.Purchase.Month
    belongs_to :signoff, Nila.Gst.Filing.Signoff
    belongs_to :org, Nila.Orgs.Org

    timestamps(updated_at: false)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:kind, :tax_heads, :tax_paise])
    |> validate_required([
      :case_id,
      :client_month_id,
      :signoff_id,
      :org_id,
      :kind,
      :tax_heads,
      :tax_paise
    ])
    |> validate_inclusion(:kind, ["original_claim"])
    |> validate_number(:tax_paise, greater_than: 0)
    |> validate_heads()
    |> unique_constraint([:case_id, :client_month_id, :kind],
      name: :gst_itc_allocations_live_entitlement_index
    )
  end

  defp validate_heads(changeset) do
    heads = get_field(changeset, :tax_heads)

    if Nila.Gst.Purchase.ItcTreatment.valid?(heads) and
         Nila.Gst.Purchase.ItcTreatment.sum(heads) == get_field(changeset, :tax_paise),
       do: changeset,
       else:
         add_error(
           changeset,
           :tax_heads,
           "must balance the claim amount with nonnegative whole paise"
         )
  end
end
