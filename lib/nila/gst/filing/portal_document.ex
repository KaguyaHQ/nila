defmodule Nila.Gst.Filing.PortalDocument do
  @moduledoc """
  Identifies the structured JSON files downloaded from the GST portal.

  Classification is deliberately shape-based and refuses unknown or ambiguous
  documents. A portal file routed to the wrong side of a month can quietly
  corrupt the return it feeds.
  """

  alias Nila.Gst.Filing.Gstr2b

  @gstr1_sections ~w(b2b b2cl b2cs cdnr cdnur exp at atadj txpd nil)

  def classify(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> classify(document)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def classify(%{} = document) do
    case {Gstr2b.recognized?(document), filed_gstr1?(document)} do
      {true, false} -> {:ok, "gstr2b"}
      {false, true} -> {:ok, "filed_gstr1"}
      {false, false} -> {:error, :unrecognized_structure}
      {true, true} -> {:error, :ambiguous_structure}
    end
  end

  def classify(_document), do: {:error, :unrecognized_structure}

  def parse_filed_gstr1(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> parse_filed_gstr1(document)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def parse_filed_gstr1(%{} = document) do
    if filed_gstr1?(document),
      do: {:ok, document},
      else: {:error, :not_a_filed_gstr1}
  end

  def parse_filed_gstr1(_document), do: {:error, :not_a_filed_gstr1}

  defp filed_gstr1?(%{"gstin" => gstin, "fp" => period} = document)
       when is_binary(gstin) and is_binary(period) do
    Enum.any?(@gstr1_sections, &Map.has_key?(document, &1))
  end

  defp filed_gstr1?(_document), do: false
end
