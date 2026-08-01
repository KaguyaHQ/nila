defmodule Nila.ContactRequest do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :firm, :string
    field :phone, :string
    field :website, :string
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:name, :firm, :phone, :website])
    |> update_change(:name, &String.trim/1)
    |> update_change(:firm, &String.trim/1)
    |> update_change(:phone, &String.trim/1)
    |> validate_required([:name, :firm, :phone])
    |> validate_length(:name, max: 100)
    |> validate_length(:firm, max: 160)
    |> validate_length(:phone, max: 30)
    |> validate_format(:name, ~r/\A[^\r\n]+\z/)
    |> validate_format(:firm, ~r/\A[^\r\n]+\z/)
    |> validate_format(:phone, ~r/\A\+?\(?[0-9][0-9 ()-]*\z/,
      message: "must be a valid phone number"
    )
    |> validate_change(:phone, &validate_phone_digits/2)
  end

  def spam?(attrs) when is_map(attrs) do
    website = Map.get(attrs, "website") || Map.get(attrs, :website)
    is_binary(website) && String.trim(website) != ""
  end

  defp validate_phone_digits(:phone, phone) do
    case phone |> String.replace(~r/\D/, "") |> String.length() do
      count when count in 8..15 -> []
      _ -> [phone: "must contain between 8 and 15 digits"]
    end
  end
end
