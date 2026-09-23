defmodule Nila.Business.Profile do
  use Nila.Schema

  schema "business_profiles" do
    belongs_to :client, Nila.Clients.Client
    field :legal_name, :string
    field :address, :string
    field :state_code, :string
    field :e_invoice_not_applicable, :boolean, default: false
    field :domestic_services_only, :boolean, default: false
    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :legal_name,
      :address,
      :state_code,
      :e_invoice_not_applicable,
      :domestic_services_only
    ])
    |> validate_required([:legal_name, :address, :state_code])
    |> validate_length(:legal_name, max: 200)
    |> validate_length(:address, max: 2000)
    |> validate_inclusion(
      :state_code,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> unique_constraint(:client_id)
  end
end
