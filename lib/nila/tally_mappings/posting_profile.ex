defmodule Nila.TallyMappings.PostingProfile do
  use Nila.Schema

  @ledger_fields [
    :sales_ledger_identity,
    :cgst_ledger_identity,
    :sgst_ledger_identity,
    :igst_ledger_identity
  ]

  schema "tally_posting_profiles" do
    field :sales_ledger_identity, :string
    field :cgst_ledger_identity, :string
    field :sgst_ledger_identity, :string
    field :igst_ledger_identity, :string
    belongs_to :org, Nila.Orgs.Org
    belongs_to :company, Nila.TallyDevices.Company
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @ledger_fields)
    |> validate_required([:org_id, :company_id])
    |> validate_at_least_one_ledger()
    |> unique_constraint([:company_id])
  end

  def ledger_fields, do: @ledger_fields

  defp validate_at_least_one_ledger(changeset) do
    if Enum.any?(@ledger_fields, &present?(get_field(changeset, &1))),
      do: changeset,
      else: add_error(changeset, :sales_ledger_identity, "select at least one posting ledger")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
