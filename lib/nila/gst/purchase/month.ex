defmodule Nila.Gst.Purchase.Month do
  use Nila.Schema
  import Ecto.Changeset

  @states ~w(collecting worked reviewed filed)

  def states, do: @states

  schema "client_months" do
    field :period, :string
    field :state, :string, default: "worked"
    field :register_rows, {:array, :map}, default: []
    field :recon, :map, default: %{}
    field :summary, :map, default: %{}
    field :filed_at, :utc_datetime_usec
    field :filing_arn, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :filed_by, Nila.Accounts.User

    timestamps()
  end

  def changeset(client_month, attrs) do
    client_month
    |> cast(attrs, [:period, :state, :register_rows, :recon, :summary, :filing_arn])
    |> validate_required([:org_id, :client_id, :period, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:client_id, :period])
  end
end
