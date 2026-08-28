defmodule Nila.TallyDevices.CompanyDevice do
  use Nila.Schema

  schema "tally_company_devices" do
    field :is_open, :boolean, default: false
    field :last_seen_at, :utc_datetime_usec

    belongs_to :company, Nila.TallyDevices.Company
    belongs_to :device, Nila.TallyDevices.Device

    timestamps()
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [:is_open, :last_seen_at])
    |> validate_required([:company_id, :device_id, :is_open, :last_seen_at])
    |> unique_constraint([:company_id, :device_id])
  end
end
