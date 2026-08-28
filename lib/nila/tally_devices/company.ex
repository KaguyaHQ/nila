defmodule Nila.TallyDevices.Company do
  use Nila.Schema

  schema "tally_companies" do
    field :identity, :string
    field :name, :string
    field :tally_guid, :string
    field :gstin, :string
    # Compatibility projection for callers that need the currently selected route.
    # Company identity is independent of connector installations; these fields are
    # populated by Nila.TallyDevices from a CompanyDevice route.
    field :is_open, :boolean, virtual: true, default: false
    field :last_seen_at, :utc_datetime_usec, virtual: true
    field :device_id, :integer, virtual: true
    field :device, :map, virtual: true

    belongs_to :org, Nila.Orgs.Org
    has_many :device_routes, Nila.TallyDevices.CompanyDevice
    has_one :client, Nila.Clients.Client, foreign_key: :active_tally_company_id

    timestamps()
  end

  def changeset(company, attrs) do
    company
    |> cast(attrs, [:name, :tally_guid, :gstin])
    |> update_change(:name, &String.trim/1)
    |> update_change(:tally_guid, &normalize_optional/1)
    |> update_change(:gstin, &normalize_optional/1)
    |> validate_required([:org_id, :identity, :name])
    |> validate_length(:identity, max: 260)
    |> validate_length(:name, max: 200)
    |> validate_length(:tally_guid, max: 200)
    |> validate_length(:gstin, max: 15)
    |> unique_constraint([:org_id, :identity])
  end

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
