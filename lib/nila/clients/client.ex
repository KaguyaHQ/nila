defmodule Nila.Clients.Client do
  use Nila.Schema
  import Ecto.Changeset

  @types ~w(company individual partnership trust)
  @chase_channels ~w(none whatsapp email)

  def types, do: @types
  def chase_channels, do: @chase_channels

  schema "clients" do
    field :name, :string
    field :type, :string
    field :address, :string
    field :pan, :string
    field :gstin, :string
    field :phone, :string
    field :email, :string
    field :chase_channel, :string, default: "none"
    field :match_hints, {:array, :string}, default: []

    belongs_to :org, Nila.Orgs.Org
    has_many :tally_companies, Nila.TallyDevices.Company

    timestamps()
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :org_id,
      :name,
      :type,
      :address,
      :pan,
      :gstin,
      :phone,
      :email,
      :chase_channel,
      :match_hints
    ])
    |> validate_required([:org_id, :name, :type, :chase_channel])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:chase_channel, @chase_channels)
    |> update_change(:pan, &normalize_upcase/1)
    |> update_change(:gstin, &normalize_upcase/1)
    |> update_change(:phone, &normalize_phone/1)
    |> update_change(:email, &normalize_email/1)
    |> update_change(:address, &normalize_blank/1)
    |> update_change(:match_hints, &normalize_hints/1)
    |> validate_format(:pan, ~r/^[A-Z]{5}[0-9]{4}[A-Z]$/, allow_nil: true)
    |> validate_format(:phone, ~r/^\d{11,15}$/, allow_nil: true)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, allow_nil: true)
    |> validate_channel_contact()
    |> Nila.Gstin.validate_gstin(:gstin)
    |> unique_constraint([:org_id, :name])
    |> unique_constraint(:phone, name: :clients_org_id_phone_index)
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

  def normalize_phone(nil), do: nil

  def normalize_phone(value) when is_binary(value) do
    digits = String.replace(value, ~r/[^0-9]/, "")

    case digits do
      "" -> nil
      "00" <> international -> international
      "0" <> <<local::binary-size(10)>> -> "91" <> local
      <<_::binary-size(10)>> -> "91" <> digits
      digits -> digits
    end
  end

  def normalize_email(nil), do: nil

  def normalize_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&if(&1 == "", do: nil, else: &1))
  end

  defp validate_channel_contact(changeset) do
    case get_field(changeset, :chase_channel) do
      "whatsapp" -> require_contact(changeset, :phone, "is required for WhatsApp chases")
      "email" -> require_contact(changeset, :email, "is required for email chases")
      _ -> changeset
    end
  end

  defp require_contact(changeset, field, message) do
    if get_field(changeset, field), do: changeset, else: add_error(changeset, field, message)
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value),
    do: value |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))
end
