defmodule Nila.TallyDevices.Pairing do
  use Nila.Schema

  schema "tally_device_pairings" do
    field :device_code_hash, :binary, redact: true
    field :approval_code_hash, :binary, redact: true
    field :device_name, :string
    field :connector_version, :string
    field :expires_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :exchanged_at, :utc_datetime_usec

    belongs_to :org, Nila.Orgs.Org
    belongs_to :approved_by_user, Nila.Accounts.User
    belongs_to :device, Nila.TallyDevices.Device

    timestamps()
  end

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs, [:device_name, :connector_version])
    |> update_change(:device_name, &String.trim/1)
    |> update_change(:connector_version, &normalize_optional/1)
    |> validate_required([:device_name])
    |> validate_length(:device_name, max: 120)
    |> validate_length(:connector_version, max: 64)
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:approval_code_hash)
  end

  defp normalize_optional(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
