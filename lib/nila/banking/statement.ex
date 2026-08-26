defmodule Nila.Banking.Statement do
  @moduledoc """
  One bank-generated statement and the structured transaction artifact read from it.

  Source credentials are encrypted only long enough for the background worker to
  open a password-protected PDF, then cleared on either success or terminal failure.
  """
  use Nila.Schema

  @statuses ~w(received extracting ready failed)
  @bank_codes ~w(hdfc iob kotak)

  schema "bank_statements" do
    field :bank_code, :string
    field :bank_ledger_name, :string
    field :bank_ledger_identity, :string
    field :status, :string, default: "received"
    field :source_key, :string
    field :source_sha256, :binary
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
    belongs_to :tally_company, Nila.TallyDevices.Company
    has_many :bank_transactions, Nila.Banking.Transaction

    timestamps()
  end

  def statuses, do: @statuses
  def bank_codes, do: @bank_codes

  def create_changeset(statement, attrs) do
    statement
    |> cast(attrs, [
      :source_key,
      :original_filename,
      :source_credentials
    ])
    |> validate_required([
      :org_id,
      :client_id,
      :status,
      :source_key,
      :original_filename
    ])
    |> validate_inclusion(:status, @statuses)
  end

  def source_hash_changeset(statement, digest) do
    statement
    |> change(source_sha256: digest)
    |> unique_constraint([:org_id, :client_id, :source_sha256])
  end
end
