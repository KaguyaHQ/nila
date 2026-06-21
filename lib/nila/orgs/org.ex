defmodule Nila.Orgs.Org do
  use Nila.Schema
  import Ecto.Changeset

  @statuses ~w(active suspended archived)

  schema "orgs" do
    field :name, :string
    field :legal_name, :string
    field :gstin, :string
    field :status, :string, default: "active"

    has_many :memberships, Nila.Orgs.Membership
    has_many :entities, Nila.Orgs.Entity
    has_many :documents, Nila.Documents.Document
    has_many :integration_connections, Nila.Integrations.Connection

    timestamps()
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :legal_name, :gstin, :status])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
    |> update_change(:gstin, &normalize_blank/1)
    |> validate_length(:gstin, is: 15)
    |> unique_constraint(:gstin)
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
