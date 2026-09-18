defmodule Nila.Gst.Portal.TaxpayerLookup do
  use Nila.Schema

  schema "gst_taxpayer_lookups" do
    field :gstin, :string
    field :legal_name, :string
    field :trade_name, :string
    field :registration_status, :string
    field :provider, :string, default: "whitebooks"
    field :payload, :map
    field :checked_at, :utc_datetime_usec
    timestamps()
  end
end
