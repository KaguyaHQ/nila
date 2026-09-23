defmodule Nila.Business.Customer do
  use Nila.Schema

  schema "business_customers" do
    belongs_to :client, Nila.Clients.Client
    field :name, :string
    field :address, :string
    field :gstin, :string
    field :state_code, :string
    timestamps()
  end

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :address, :gstin, :state_code])
    |> update_change(:gstin, fn
      nil -> nil
      value -> String.upcase(String.trim(value))
    end)
    |> validate_required([:name, :address, :state_code])
    |> validate_length(:name, max: 200)
    |> validate_length(:address, max: 2000)
    |> validate_inclusion(
      :state_code,
      Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1)
    )
    |> Nila.Gstin.validate_gstin(:gstin)
    |> validate_registration_state()
  end

  defp validate_registration_state(changeset) do
    case {get_field(changeset, :gstin), get_field(changeset, :state_code)} do
      {gstin, state} when is_binary(gstin) and is_binary(state) ->
        if String.starts_with?(gstin, state),
          do: changeset,
          else: add_error(changeset, :state_code, "must match the customer's GST registration")

      _ ->
        changeset
    end
  end
end
