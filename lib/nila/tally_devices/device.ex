defmodule Nila.TallyDevices.Device do
  use Nila.Schema

  schema "tally_devices" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :last_connected_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    has_many :company_routes, Nila.TallyDevices.CompanyDevice
    has_many :companies, through: [:company_routes, :company]

    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> unique_constraint(:token_hash)
  end
end
