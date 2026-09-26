defmodule Nila.Orgs.Org do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(active suspended archived)

  schema "orgs" do
    field :name, :string
    field :legal_name, :string
    field :gstin, :string
    field :status, :string, default: "active"
    field :is_demo, :boolean, default: false
    field :address_line1, :string
    field :address_line2, :string
    field :city, :string
    field :state, :string
    field :postal_code, :string
    field :country, :string, default: "India"
    field :contact_email, :string
    field :contact_phone, :string

    has_many :memberships, Nila.Orgs.Membership
    has_many :clients, Nila.Clients.Client
    has_many :integration_connections, Nila.Integrations.Connection

    timestamps()
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [
      :name,
      :legal_name,
      :gstin,
      :status,
      :address_line1,
      :address_line2,
      :city,
      :state,
      :postal_code,
      :country,
      :contact_email,
      :contact_phone
    ])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
    |> update_change(:gstin, &normalize_blank/1)
    |> update_change(:contact_email, &normalize_blank/1)
    |> Nila.Gstin.validate_gstin(:gstin)
    |> validate_format(:contact_email, ~r/^[^\s]+@[^\s]+$/, allow_nil: true)
    |> validate_inclusion(:state, Nila.Gst.StateCodes.all())
    |> unique_constraint(:gstin)
  end

  defdelegate indian_states, to: Nila.Gst.StateCodes, as: :all

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
