defmodule Nila.Gst.InvoiceParty do
  @moduledoc """
  Canonical party facts printed on a GST invoice.

  A party here is evidence from the document, not a customer or vendor master
  record. Missing and invalid GSTINs remain visible for validation downstream.
  """

  @enforce_keys []
  defstruct [:name, :gstin, :address, :state_code]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          gstin: String.t() | nil,
          address: String.t() | nil,
          state_code: String.t() | nil
        }

  @doc "Builds canonical party facts from a string- or atom-keyed map."
  def new(nil), do: {:ok, nil}

  def new(party) when is_map(party) do
    gstin = party |> value(:gstin) |> normalize_gstin()

    {:ok,
     %__MODULE__{
       name: normalize_text(value(party, :name)),
       gstin: gstin,
       address: normalize_text(value(party, :address)),
       state_code: normalize_state(value(party, :state_code), gstin)
     }}
  end

  def new(_party), do: {:error, :party_must_be_a_map}

  @doc "Projects party facts to a string-keyed persistence/integration map."
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = party) do
    %{
      "name" => party.name,
      "gstin" => party.gstin,
      "address" => party.address,
      "state_code" => party.state_code
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_text(nil), do: nil
  defp normalize_text(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp normalize_gstin(nil), do: nil

  defp normalize_gstin(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^0-9A-Z]/, "")
    |> blank_to_nil()
  end

  defp normalize_state(value, gstin) do
    Nila.Gst.StateCodes.normalize_code(value) || Nila.Gst.StateCodes.from_gstin(gstin)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
