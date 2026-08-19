defmodule Nila.TallyDevices.Company do
  use Nila.Schema

  schema "tally_companies" do
    field :identity, :string
    field :name, :string
    field :tally_guid, :string
    field :is_open, :boolean, default: false
    field :last_seen_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :device, Nila.TallyDevices.Device
    belongs_to :client, Nila.Clients.Client

    timestamps()
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :tally_guid])
    |> update_change(:name, &String.trim/1)
    |> update_change(:tally_guid, &normalize_optional/1)
    |> validate_required([:org_id, :device_id, :identity, :name, :last_seen_at])
    |> validate_length(:identity, max: 260)
    |> validate_length(:name, max: 200)
    |> validate_length(:tally_guid, max: 200)
    |> unique_constraint([:device_id, :identity])
  end

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
