defmodule Nila.Gst.Extraction.Sales.SellerIdentity do
  @moduledoc "Separates the selected client's identity from the seller read on a sales bill."
  alias Nila.Gstin

  def apply(data, client_gstin, text) do
    client_gstin = normalize(client_gstin)

    if Gstin.valid?(client_gstin) do
      observed = get_in(data, ["supplier", "gstin"])
      read = normalize(observed)
      source_gstin = source_registration(read, text)

      status =
        cond do
          read == client_gstin ->
            "matched"

          Gstin.valid?(read) ->
            "different"

          source_gstin == client_gstin ->
            "matched"

          is_binary(source_gstin) ->
            "different"

          true ->
            "unverified"
        end

      data
      |> Map.put("seller_identity", %{
        "client_gstin" => client_gstin,
        "observed_gstin" => observed,
        "source_gstin" => source_gstin,
        "status" => status
      })
      |> Map.update("supplier", %{"gstin" => client_gstin}, fn party ->
        Map.put(party || %{}, "gstin", client_gstin)
      end)
    else
      data
    end
  end

  # A match elsewhere on the page alone could be the buyer. Require the
  # extracted seller's entire registration number to match, apart from its checksum.
  defp checksum_misread?(read, known) when is_binary(read) and byte_size(read) == 15,
    do: binary_part(read, 0, 14) == binary_part(known, 0, 14)

  defp checksum_misread?(_, _), do: false

  defp source_registration(read, text) do
    tokens =
      Regex.scan(~r/(?<![A-Z0-9])[A-Z0-9]{15}(?![A-Z0-9])/, String.upcase(text || ""))
      |> List.flatten()

    case tokens
         |> Enum.uniq()
         |> Enum.filter(&(Gstin.valid?(&1) and checksum_misread?(read, &1))) do
      [gstin] -> gstin
      _ -> nil
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize(_), do: nil
end
