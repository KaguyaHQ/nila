defmodule Nila.Banking.Transaction do
  use Nila.Schema
  import Ecto.Changeset

  @directions ~w(credit debit)
  @modes ~w(upi neft imps cheque cash other)

  def directions, do: @directions
  def modes, do: @modes

  schema "bank_transactions" do
    field :txn_date, :date
    field :value_date, :date
    field :amount, :decimal
    field :direction, :string
    field :balance, :decimal
    field :narration, :string
    field :ref, :string
    field :mode, :string
    field :txn_id, :string
    field :raw, :map, default: %{}

    belongs_to :org, Nila.Orgs.Org
    belongs_to :bank_account, Nila.Banking.Account
    belongs_to :client, Nila.Clients.Client

    timestamps()
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :org_id,
      :bank_account_id,
      :txn_date,
      :value_date,
      :amount,
      :direction,
      :balance,
      :narration,
      :ref,
      :mode,
      :txn_id,
      :raw
    ])
    |> validate_required([:org_id, :bank_account_id, :amount, :direction, :txn_id])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:mode, @modes)
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> unique_constraint([:bank_account_id, :txn_id])
  end
end
