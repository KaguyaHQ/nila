defmodule Nila.TallyMappings.PartyMapping do
  use Nila.Schema

  schema "tally_party_mappings" do
    field :source_key, :string
    field :gstin, :string
    field :normalized_name, :string
    field :ledger_identity, :string
    field :confirmation_source, :string, default: "manual"
    field :confirmed_at, :utc_datetime_usec
    belongs_to :org, Nila.Orgs.Org
    belongs_to :company, Nila.TallyDevices.Company
    timestamps()
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :source_key,
      :gstin,
      :normalized_name,
      :ledger_identity,
      :confirmation_source,
      :confirmed_at
    ])
    |> validate_required([
      :org_id,
      :company_id,
      :source_key,
      :ledger_identity,
      :confirmation_source,
      :confirmed_at
    ])
    |> validate_inclusion(:confirmation_source, ["manual"])
    |> validate_length(:source_key, max: 400)
    |> validate_length(:gstin, max: 15)
    |> validate_length(:normalized_name, max: 300)
    |> validate_length(:ledger_identity, max: 300)
    |> unique_constraint([:company_id, :source_key])
  end
end
