defmodule Nila.Business.Service do
  use Nila.Schema

  schema "business_services" do
    belongs_to :client, Nila.Clients.Client
    field :description, :string
    field :sac, :string
    field :unit, :string, default: "service"
    field :unit_price, :decimal
    field :gst_rate, :decimal
    timestamps()
  end

  def changeset(service, attrs) do
    service
    |> cast(attrs, [:description, :sac, :unit, :unit_price, :gst_rate])
    |> validate_required([:description, :sac, :unit, :unit_price, :gst_rate])
    |> validate_length(:description, max: 1000)
    |> validate_length(:unit, max: 30)
    |> validate_format(:sac, ~r/^99\d{4}$/)
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

  defp validate_decimal(changeset, field, places) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(value, Decimal.round(value, places)),
        do: [],
        else: [{field, "has too many decimal places"}]
    end)
  end
end
