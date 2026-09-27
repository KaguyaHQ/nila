defmodule Nila.Business.Profile do
  use Nila.Schema

  schema "business_profiles" do
    belongs_to :client, Nila.Clients.Client
    field :legal_name, :string
    field :address, :string
    field :state_code, :string
    field :phone, :string
    field :email, :string
    field :logo_key, :string
    field :signature_key, :string
    field :quotation_number_style, :string, default: "nila"
    field :quotation_number_prefix, :string
    field :quotation_number_min_digits, :integer, default: 1
    field :invoice_number_style, :string, default: "nila"
    field :e_invoice_not_applicable, :boolean, default: false
    field :domestic_services_only, :boolean, default: false
    field :domestic_goods_and_services_only, :boolean, default: false
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :legal_name,
      :address,
      :state_code,
      :phone,
      :email,
      :e_invoice_not_applicable,
      :domestic_services_only,
      :domestic_goods_and_services_only
    ])
    |> validate_required([:legal_name, :address, :state_code])
    |> validate_length(:legal_name, max: 200)
    |> validate_length(:address, max: 2000)
    |> validate_length(:phone, max: 40)
    |> validate_length(:email, max: 254)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> validate_inclusion(
      :state_code,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> unique_constraint(:client_id)
  end
end
