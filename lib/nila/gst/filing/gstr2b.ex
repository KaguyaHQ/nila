defmodule Nila.Gst.Filing.Gstr2b do
  @moduledoc """
  Parser/normalizer for the GSTR-2B JSON downloaded from the GST portal.

  Flattens the portal's supplier-grouped B2B and CDNR sections into one plain
  map per document, with all money converted from rupee floats to integer paise so the
  reconciler never touches floats. Pure: takes a decoded map (or raw JSON
  binary), returns plain maps, no DB, no IO.

  Verified against a real portal download (Oct 2025, v1.0): top-level
  `%{"data" => %{"docdata" => %{"b2b" => [...]}}}`, with tolerance for dumps
  that start at `"docdata"` directly. Real dumps carry `txval`/`cgst`/`sgst`/
  `igst` directly on each invoice; some documented variants nest per-rate
  `items` instead — both are handled, invoice-level fields winning when present.
  """

  @doc """
  Parses a GSTR-2B document (decoded map or JSON binary) into
  `{:ok, [invoice]}` where each invoice is:

      %{
        "vendor_gstin" => String.t(),
        "vendor_name" => String.t() | nil,
        "invoice_number" => String.t(),
        "invoice_date" => Date.t() | nil,
        "total_paise" => integer,
        "taxable_paise" => integer,
        "tax_paise" => %{"cgst" => integer, "sgst" => integer, "igst" => integer},
        "itc_available" => boolean,
        "itc_reason" => String.t() | nil,
        "reverse_charge" => boolean,
        "pos" => String.t() | nil
      }

  Returns `{:error, :invalid_json}` for undecodable binaries and
  `{:error, :unrecognized_structure}` when neither wrapper shape is present.
  """
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> parse(map)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  def parse(%{} = map) do
    case docdata(map) do
      %{} = docdata ->
        invoices = docdata |> Map.get("b2b", []) |> Enum.flat_map(&supplier_invoices/1)
        notes = docdata |> Map.get("cdnr", []) |> Enum.flat_map(&supplier_notes/1)

        {:ok, invoices ++ notes}

      _ ->
        {:error, :unrecognized_structure}
    end
  end

  def parse(_), do: {:error, :unrecognized_structure}

  @doc false
  def recognized?(%{} = document), do: is_map(docdata(document))
  def recognized?(_document), do: false

  defp docdata(%{"data" => %{"docdata" => %{} = docdata}}), do: docdata
  defp docdata(%{"docdata" => %{} = docdata}), do: docdata
  defp docdata(_), do: nil

  defp supplier_invoices(%{"ctin" => ctin} = supplier) do
    trade_name = supplier["trdnm"]

    supplier
    |> Map.get("inv", [])
    |> Enum.map(&normalize_invoice(&1, ctin, trade_name))
  end

  defp supplier_invoices(_), do: []

  defp supplier_notes(%{"ctin" => ctin} = supplier) do
    trade_name = supplier["trdnm"]

    supplier
    |> Map.get("nt", [])
    |> Enum.map(&normalize_note(&1, ctin, trade_name))
  end

  defp supplier_notes(_), do: []

  defp normalize_invoice(inv, ctin, trade_name) do
    items = List.wrap(inv["items"])

    %{
      "document_type" => "invoice",
      "source_section" => "b2b",
      "vendor_gstin" => ctin,
      "vendor_name" => trade_name,
      "invoice_number" => to_string(inv["inum"] || ""),
      "invoice_date" => parse_date(inv["dt"]),
      "total_paise" => paise(inv["val"]),
      "taxable_paise" => amount(inv, items, "txval"),
      "tax_paise" => %{
        "cgst" => amount(inv, items, "cgst"),
        "sgst" => amount(inv, items, "sgst"),
        "igst" => amount(inv, items, "igst")
      },
      "itc_available" => inv["itcavl"] == "Y",
      "itc_reason" => inv["rsn"],
      "reverse_charge" => inv["rev"] == "Y",
      "pos" => pos(inv["pos"])
    }
  end

  defp normalize_note(note, ctin, trade_name) do
    %{
      "document_type" => note_type(note["typ"]),
      "source_section" => "cdnr",
      "vendor_gstin" => ctin,
      "vendor_name" => trade_name,
      "invoice_number" => to_string(note["ntnum"] || ""),
      "invoice_date" => parse_date(note["dt"]),
      "total_paise" => paise(note["val"]),
      "taxable_paise" => paise(note["txval"]),
      "tax_paise" => %{
        "cgst" => paise(note["cgst"]),
        "sgst" => paise(note["sgst"]),
        "igst" => paise(note["igst"])
      },
      "itc_available" => note["itcavl"] == "Y",
      "itc_reason" => note["rsn"],
      "reverse_charge" => note["rev"] == "Y",
      "pos" => pos(note["pos"]),
      "ims_status" => note["imsStatus"]
    }
  end

  defp note_type("C"), do: "credit_note"
  defp note_type("D"), do: "debit_note"
  defp note_type(_unknown), do: "unknown"

  defp amount(inv, items, key) do
    case inv[key] do
      value when is_number(value) -> paise(value)
      _ -> sum_items(items, key)
    end
  end

  defp sum_items(items, key) do
    Enum.reduce(items, 0, fn item, acc -> acc + paise(item[key]) end)
  end

  defp paise(value) when is_number(value), do: round(value * 100)
  defp paise(_), do: 0

  defp pos(nil), do: nil
  defp pos(value), do: to_string(value)

  defp parse_date(<<d::binary-size(2), "-", m::binary-size(2), "-", y::binary-size(4)>>) do
    case Date.from_iso8601("#{y}-#{m}-#{d}") do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_), do: nil
end
