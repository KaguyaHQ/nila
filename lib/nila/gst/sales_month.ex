defmodule Nila.Gst.SalesMonth do
  @moduledoc """
  A client's worked outward (sales) GST month: the extracted `invoices`, the
  `derived_gstr1` portal-shaped return, the validation `issues`, and a display
  `summary`, stored as JSON blobs. The outward mirror of `Nila.Gst.ClientMonth`
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

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client

    timestamps()
  end

  def changeset(sales_month, attrs) do
    sales_month
    |> cast(attrs, [:period, :state, :invoices, :derived_gstr1, :issues, :summary])
    |> validate_required([:org_id, :client_id, :period, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:client_id, :period])
  end
end
