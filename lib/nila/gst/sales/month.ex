defmodule Nila.Gst.Sales.Month do
  @moduledoc """
  A client's worked outward (sales) GST month: the extracted `invoices`, the
  `derived_gstr1` portal-shaped return, the validation `issues`, and a display
  `summary`, stored as JSON blobs. The outward mirror of `Nila.Gst.Purchase.Month`
  (which holds the purchase-side `register_rows`/`recon`); this holds the
  GSTR-1 payload instead.
  """
  use Nila.Schema
  import Ecto.Changeset

  @states ~w(collecting worked reviewed filed)

  def states, do: @states

  schema "sales_months" do
    field :period, :string
    field :state, :string, default: "worked"
    field :invoices, {:array, :map}, default: []
    field :derived_gstr1, :map, default: %{}
    field :issues, {:array, :map}, default: []
    field :summary, :map, default: %{}
    field :filed_gstr1, :map
    field :filed_at, :utc_datetime_usec
    field :filing_arn, :string
    field :cess_evaluated, :boolean, default: false

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :hsn_master_release, Nila.Gst.Hsn.Release
    belongs_to :gst_rate_release, Nila.Gst.Rates.Release
    belongs_to :filed_by, Nila.Accounts.User

    timestamps()
  end

  def changeset(sales_month, attrs) do
    sales_month
    |> cast(attrs, [
      :period,
      :state,
      :invoices,
      :derived_gstr1,
      :issues,
      :summary,
      :filed_gstr1,
      :filing_arn,
      :cess_evaluated
    ])
    |> validate_required([:org_id, :client_id, :period, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:client_id, :period])
  end
end
