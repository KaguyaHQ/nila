defmodule Nila.Banking.Statement do
  @moduledoc """
  One bank-generated statement and the structured transaction artifact read from it.

  Source credentials are encrypted only long enough for the background worker to
  open a password-protected PDF, then cleared on either success or terminal failure.
  """
  use Nila.Schema

  @statuses ~w(received extracting ready failed)
  @bank_codes ~w(hdfc kotak)

  schema "bank_statements" do
    field :bank_code, :string
    field :bank_name, :string
    field :bank_ledger_name, :string
    field :status, :string, default: "received"
    field :source_key, :string
    field :original_filename, :string
    field :source_credentials, Nila.EncryptedMap
    field :account_number_masked, :string
    field :statement_from, :date
    field :statement_to, :date
    field :opening_balance_paise, :integer
    field :closing_balance_paise, :integer
    field :total_withdrawal_paise, :integer
    field :total_deposit_paise, :integer
    field :transaction_count, :integer, default: 0
    field :transactions, {:array, :map}, default: []
    field :meta, :map, default: %{}
    field :error, :string

    belongs_to :org, Nila.Orgs.Org
    belongs_to :client, Nila.Clients.Client
    belongs_to :brought_in_by, Nila.Accounts.User

    timestamps()
  end

  def statuses, do: @statuses
  def bank_codes, do: @bank_codes

  def create_changeset(statement, attrs) do
    statement
    |> cast(attrs, [
      :bank_code,
      :bank_name,
      :bank_ledger_name,
      :source_key,
      :original_filename,
      :source_credentials
    ])
    |> update_change(:bank_ledger_name, &String.trim/1)
    |> validate_required([
      :org_id,
      :client_id,
      :bank_code,
      :bank_name,
      :bank_ledger_name,
      :status,
      :source_key,
      :original_filename
    ])
    |> validate_inclusion(:bank_code, @bank_codes)
    |> validate_inclusion(:status, @statuses)
  end
end
