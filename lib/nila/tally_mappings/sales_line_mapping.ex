defmodule Nila.TallyMappings.SalesLineMapping do
  use Nila.Schema

  schema "tally_sales_line_mappings" do
    field :source_key, :string
    field :hsn_sac, :string
    field :normalized_description, :string
    field :ledger_identity, :string
    field :confirmed_at, :utc_datetime_usec
    belongs_to :org, Nila.Orgs.Org
    belongs_to :company, Nila.TallyDevices.Company
    timestamps()
  end

  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :source_key,
      :hsn_sac,
      :normalized_description,
      :ledger_identity,
      :confirmed_at
    ])
    |> validate_required([
      :org_id,
      :company_id,
      :source_key,
      :normalized_description,
      :ledger_identity,
      :confirmed_at
    ])
    |> validate_length(:source_key, max: 150)
    |> validate_length(:hsn_sac, max: 20)
    |> validate_length(:normalized_description, max: 500)
    |> validate_length(:ledger_identity, max: 300)
    |> unique_constraint([:company_id, :source_key])
  end
end
