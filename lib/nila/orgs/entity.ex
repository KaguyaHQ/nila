defmodule Nila.Orgs.Entity do
  use Nila.Schema
  import Ecto.Changeset

  schema "org_entities" do
    field :name, :string
    field :gstin, :string
    field :address_line1, :string
    field :address_line2, :string
    field :city, :string
    field :state, :string
    field :postal_code, :string
    field :country, :string, default: "India"
    field :contact_email, :string
    field :contact_phone, :string
    field :bank_account_holder, :string
    field :bank_account_number, Nila.EncryptedString
    field :bank_ifsc, :string
    field :bank_name, :string
    field :invoice_prefix, :string, default: ""
    field :invoice_next, :integer, default: 1
    field :invoice_padding, :integer, default: 0
    field :fiscal_year_start_month, :integer, default: 4

    belongs_to :org, Nila.Orgs.Org
    has_many :integration_connections, Nila.Integrations.Connection

    timestamps()
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :org_id,
      :name,
      :gstin,
      :address_line1,
      :address_line2,
      :city,
      :state,
      :postal_code,
      :country,
      :contact_email,
      :contact_phone,
      :bank_account_holder,
      :bank_account_number,
      :bank_ifsc,
      :bank_name,
      :invoice_prefix,
      :invoice_next,
      :invoice_padding,
      :fiscal_year_start_month
    ])
    |> validate_required([
      :org_id,
      :name,
      :invoice_next,
      :invoice_padding,
      :fiscal_year_start_month
    ])
    |> update_change(:gstin, &normalize_blank/1)
    |> update_change(:bank_ifsc, &normalize_blank/1)
    |> update_change(:contact_email, &normalize_blank/1)
    |> Nila.Gstin.validate_gstin(:gstin)
    |> validate_format(:contact_email, ~r/^[^\s]+@[^\s]+$/, allow_nil: true)
    |> validate_format(:bank_ifsc, ~r/^[A-Z]{4}0[A-Z0-9]{6}$/, allow_nil: true)
    |> validate_inclusion(:state, Nila.Gst.StateCodes.all())
    |> validate_number(:invoice_next, greater_than: 0)
    |> validate_number(:invoice_padding, greater_than_or_equal_to: 0, less_than_or_equal_to: 12)
    |> validate_number(:fiscal_year_start_month, equal_to: 4)
    |> unique_constraint(:gstin)
    |> unique_constraint([:org_id, :name])
  end

  defdelegate indian_states, to: Nila.Gst.StateCodes, as: :all

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
