defmodule Nila.Clients.Client do
  use Nila.Schema
  import Ecto.Changeset

  @types ~w(company individual partnership trust)

  def types, do: @types

  schema "clients" do
    field :name, :string
    field :type, :string
    field :address, :string
    field :pan, :string
    field :gstin, :string
    field :phone, :string
    field :match_hints, {:array, :string}, default: []

    belongs_to :org, Nila.Orgs.Org

    timestamps()
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:org_id, :name, :type, :address, :pan, :gstin, :phone, :match_hints])
    |> validate_required([:org_id, :name, :type])
    |> validate_inclusion(:type, @types)
    |> update_change(:pan, &normalize_upcase/1)
    |> update_change(:gstin, &normalize_upcase/1)
    |> update_change(:phone, &normalize_blank/1)
    |> update_change(:address, &normalize_blank/1)
    |> update_change(:match_hints, &normalize_hints/1)
    |> validate_format(:pan, ~r/^[A-Z]{5}[0-9]{4}[A-Z]$/, allow_nil: true)
    |> Nila.Gstin.validate_gstin(:gstin)
    |> unique_constraint([:org_id, :name])
  end

  defp normalize_hints(nil), do: []

  defp normalize_hints(hints) when is_list(hints) do
    hints
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_upcase(nil), do: nil

  defp normalize_upcase(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase() |> then(&if(&1 == "", do: nil, else: &1))

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
