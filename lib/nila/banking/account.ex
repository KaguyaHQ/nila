defmodule Nila.Banking.Account do
  use Nila.Schema
  import Ecto.Changeset

  schema "bank_accounts" do
    field :account_number_masked, :string
    field :ifsc, :string
    field :bank_name, :string
    field :label, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :entity, Nila.Orgs.Entity
    has_many :transactions, Nila.Banking.Transaction, foreign_key: :bank_account_id

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :org_id,
      :entity_id,
      :account_number_masked,
      :ifsc,
      :bank_name,
      :label
    ])
    |> validate_required([:org_id, :entity_id])
    |> unique_constraint([:org_id, :entity_id, :account_number_masked, :ifsc],
      name: :bank_accounts_org_entity_account_ifsc_index
    )
  end
end
