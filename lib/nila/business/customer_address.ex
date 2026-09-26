defmodule Nila.Business.CustomerAddress do
  use Nila.Schema

  schema "business_customer_addresses" do
    belongs_to :client, Nila.Clients.Client
    belongs_to :customer, Nila.Business.Customer
    field :label, :string
    field :address, :string
    field :state_code, :string
    field :gstin, :string
    field :usage, :string, default: "either"
    field :is_primary_billing, :boolean, default: false
    field :is_primary_shipping, :boolean, default: false
    timestamps()
  end

  def changeset(address, attrs) do
    address
    |> cast(attrs, [
      :label,
      :address,
      :state_code,
      :gstin,
      :usage,
      :is_primary_billing,
      :is_primary_shipping
    ])
    |> update_change(:gstin, fn
      nil ->
        nil

      value ->
        gstin = value |> String.trim() |> String.upcase()
        if gstin == "", do: nil, else: gstin
    end)
    |> validate_required([:label, :address, :state_code, :usage])
    |> validate_length(:label, max: 100)
    |> validate_length(:address, max: 2000)
    |> validate_inclusion(:usage, ~w(billing shipping either))
    |> validate_inclusion(
      :state_code,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> Nila.Gstin.validate_gstin(:gstin)
    |> validate_registration_state()
    |> validate_primary_usage()
  end

  defp validate_registration_state(changeset) do
    case {get_field(changeset, :gstin), get_field(changeset, :state_code)} do
      {gstin, state} when is_binary(gstin) and is_binary(state) ->
        if String.starts_with?(gstin, state),
          do: changeset,
          else: add_error(changeset, :state_code, "must match the GST registration")

      _ ->
        changeset
    end
  end

  defp validate_primary_usage(changeset) do
    usage = get_field(changeset, :usage)

    changeset =
      if get_field(changeset, :is_primary_billing) and usage == "shipping",
        do: add_error(changeset, :usage, "must allow billing for the primary billing address"),
        else: changeset

    if get_field(changeset, :is_primary_shipping) and usage == "billing",
      do: add_error(changeset, :usage, "must allow shipping for the primary shipping address"),
      else: changeset
  end
end
