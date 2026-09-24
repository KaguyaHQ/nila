defmodule Nila.Business.Service do
  use Nila.Schema

  schema "business_services" do
    belongs_to :client, Nila.Clients.Client
    field :description, :string
    field :sac, :string
    field :kind, :string, default: "service"
    field :unit, :string, default: "service"
    field :unit_price, :decimal
    field :gst_rate, :decimal
    timestamps()
  end

  def changeset(service, attrs) do
    service
    |> cast(attrs, [:description, :sac, :kind, :unit, :unit_price, :gst_rate])
    |> validate_required([:description, :sac, :kind, :unit, :unit_price, :gst_rate])
    |> validate_inclusion(:kind, ~w(goods service))
    |> validate_length(:description, max: 1000)
    |> validate_length(:unit, max: 30)
    |> validate_code()
    |> validate_unit()
    |> validate_number(:unit_price, greater_than: 0, less_than_or_equal_to: 1_000_000_000)
    |> validate_number(:gst_rate, greater_than: 0, less_than_or_equal_to: 40)
    |> validate_decimal(:unit_price, 2)
    |> validate_decimal(:gst_rate, 3)
    |> validate_change(:gst_rate, fn :gst_rate, rate ->
      if Decimal.to_string(Decimal.normalize(rate), :normal) in ~w(0.1 0.25 1 1.5 3 5 6 7.5 12 18 28 40),
        do: [],
        else: [gst_rate: "must be a supported GST rate"]
    end)
  end

  defp validate_code(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :sac)} do
      {"service", code} when is_binary(code) ->
        validate_format(changeset, :sac, ~r/^99\d{4}$/)

      {"goods", code} when is_binary(code) ->
        validate_format(changeset, :sac, ~r/^(?!99)\d{6}(\d{2})?$/)

      _ ->
        changeset
    end
  end

  defp validate_unit(changeset) do
    if get_field(changeset, :kind) == "goods",
      do: validate_inclusion(changeset, :unit, ~w(NOS KGS LTR MTR BOX SET)),
      else: changeset
  end

  defp validate_decimal(changeset, field, places) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(value, Decimal.round(value, places)),
        do: [],
        else: [{field, "has too many decimal places"}]
    end)
  end
end
