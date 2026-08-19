defmodule Nila.Banking.Transaction do
  use Nila.Schema

  @types ~w(payment receipt contra_withdrawal contra_deposit)
  @statuses ~w(unassigned ready queued posted failed verifying ignored)

  schema "bank_transactions" do
    field :identity, :string
    field :ordinal, :integer
    field :date, :date
    field :narration, :string
    field :reference, :string
    field :withdrawal_paise, :integer, default: 0
    field :deposit_paise, :integer, default: 0
    field :balance_paise, :integer
    field :transaction_type, :string
    field :counter_ledger_identity, :string
    field :counter_ledger_name, :string
    field :status, :string, default: "unassigned"
    field :tally_master_id, :integer
    field :tally_guid, :string
    field :error, :map

    belongs_to :org, Nila.Orgs.Org
    belongs_to :statement, Nila.Banking.Statement
    belongs_to :tally_job, Nila.TallyJobs.Job

    timestamps()
  end

  def types, do: @types
  def statuses, do: @statuses

  def mapping_changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:transaction_type, :counter_ledger_identity, :counter_ledger_name, :status])
    |> validate_required([:transaction_type, :status])
    |> validate_inclusion(:transaction_type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:counter_ledger_identity, max: 300)
    |> validate_length(:counter_ledger_name, max: 300)
    |> validate_direction()
  end

  defp validate_direction(changeset) do
    type = get_field(changeset, :transaction_type)
    withdrawal = get_field(changeset, :withdrawal_paise) || 0
    deposit = get_field(changeset, :deposit_paise) || 0

    valid? =
      (withdrawal != 0 and deposit == 0 and type in ~w(payment contra_withdrawal)) or
        (deposit != 0 and withdrawal == 0 and type in ~w(receipt contra_deposit))

    if valid?,
      do: changeset,
      else: add_error(changeset, :transaction_type, "does not match amount direction")
  end
end
