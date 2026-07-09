defmodule Nila.Gst.PurchaseBooks do
  @moduledoc """
  Turns per-page purchase extraction artifacts into the books-side invoice
  contract consumed by `Nila.Gst.Recon` and `Nila.Gst.Flags`.

  Pure: takes plain maps (decoded page artifacts), returns plain maps. Handles
  the realities of merged scan dumps: multi-page invoices (grouped by
  continuation flag or by same vendor GSTIN + invoice number on consecutive
  pages), GSTINs printed with separators (`33-AEWPH4158J-1Z3`), rupee floats,
  and mixed date formats.
  """

  @doc """
  Groups page artifacts into invoices and normalizes each to:

      %{
        "id" => "inv_03",
        "pages" => [3, 4],
        "images" => ["images/page_03.png", ...],
        "vendor_name" => String.t() | nil,
        "vendor_gstin" => String.t() | nil,
        "invoice_number" => String.t() | nil,
        "invoice_date" => Date.t() | nil,
        "delivery_address" => String.t() | nil,
        "line_items" => [%{"description", "hsn_sac", "taxable_paise"}],
        "taxable_paise" => integer,
        "tax_paise" => %{"cgst" => integer, "sgst" => integer, "igst" => integer},
        "total_paise" => integer,
        "skipped_pages" => absent; see `normalize/1` return
      }

  Returns `%{"invoices" => [...], "skipped_pages" => [%{"page", "reason"}]}` —
  non-invoice pages are confessed, never silently dropped.
  """
  def normalize(page_artifacts) when is_list(page_artifacts) do
    pages =
      page_artifacts
      |> Enum.map(&normalize_page/1)
      |> Enum.sort_by(& &1["page"])

    {groups, skipped} = group_pages(pages)

    invoices =
      groups
      |> Enum.with_index(1)
      |> Enum.map(fn {group, index} -> build_invoice(group, index) end)

    %{"invoices" => invoices, "skipped_pages" => skipped}
  end

  @doc """
  Normalizes a printed GSTIN: uppercased, separators stripped. Returns the
  cleaned value only when it passes `Nila.Gstin.valid?/1`; otherwise returns
  the cleaned string tagged invalid so callers can flag rather than discard.
  """
  def clean_gstin(nil), do: {:missing, nil}

  def clean_gstin(value) when is_binary(value) do
    cleaned =
      value
      |> String.upcase()
      |> String.replace(~r/[^0-9A-Z]/, "")

    cond do
      cleaned == "" -> {:missing, nil}
      Nila.Gstin.valid?(cleaned) -> {:ok, cleaned}
      true -> {:invalid, cleaned}
    end
  end

  @doc """
  Parses printed invoice dates: `DD.MM.YYYY`, `DD/MM/YYYY`, `DD-MM-YYYY`,
  with 1-2 digit day/month and 2 or 4 digit year. Returns `Date.t()` or nil.
  """
  def parse_date(nil), do: nil

  def parse_date(value) when is_binary(value) do
    case Regex.run(~r/(\d{1,2})[.\/-](\d{1,2})[.\/-](\d{2,4})/, value) do
      [_, d, m, y] ->
        year = String.to_integer(y)
        year = if year < 100, do: 2000 + year, else: year

        case Date.new(year, String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Converts a rupee number (float/int/string) to integer paise. Nil-safe."
  def paise(nil), do: 0
  def paise(value) when is_integer(value), do: value * 100
  def paise(value) when is_float(value), do: round(value * 100)

  def paise(value) when is_binary(value) do
    cleaned = String.replace(value, ~r/[^0-9.\-]/, "")

    case Float.parse(cleaned) do
      {num, _} -> round(num * 100)
      :error -> 0
    end
  end

  defp normalize_page(artifact) do
    data = artifact["data"] || %{}
    seller = data["seller"] || %{}

    {gstin_status, gstin} = clean_gstin(seller["gstin"])

    %{
      "page" => artifact["page"],
      "image" => artifact["image"],
      "is_invoice" => data["is_invoice"] != false,
      "continuation" => data["continuation_of_previous"] == true,
      "vendor_name" => presence(seller["name"]),
      "vendor_gstin" => gstin,
      "vendor_gstin_status" => to_string(gstin_status),
      "vendor_address" => presence(seller["address"]),
      "invoice_number" => data["invoice_number"] |> presence() |> normalize_inum(),
      "invoice_date" => parse_date(data["invoice_date"]),
      "delivery_address" => presence(data["delivery_address"]),
      "line_items" => Enum.map(data["line_items"] || [], &normalize_line/1),
      "printed_grand_total" => data["printed_grand_total"],
      "printed_total_taxable" => data["printed_total_taxable"],
      "printed_total_tax" => data["printed_total_tax"],
      "confidence" => artifact["confidence"]
    }
  end

  defp normalize_line(line) do
    %{
      "description" => presence(line["description"]),
      "hsn_sac" => line["hsn_sac"] |> presence() |> strip_non_digits(),
      "quantity" => line["quantity"],
      "taxable_paise" => paise(line["taxable_value"]),
      "tax_paise" => %{
        "cgst" => paise(line["cgst_amount"]),
        "sgst" => paise(line["sgst_amount"]),
        "igst" => paise(line["igst_amount"])
      }
    }
  end

  defp group_pages(pages) do
    {groups_rev, skipped_rev} =
      Enum.reduce(pages, {[], []}, fn page, {groups, skipped} ->
        cond do
          not page["is_invoice"] and page["line_items"] == [] and
              is_nil(page["invoice_number"]) ->
            {groups, [%{"page" => page["page"], "reason" => "not_an_invoice"} | skipped]}

          groups != [] and continues_previous?(hd(groups), page) ->
            [current | rest] = groups
            {[current ++ [page] | rest], skipped}

          true ->
            {[[page] | groups], skipped}
        end
      end)

    {Enum.reverse(Enum.map(groups_rev, & &1)), Enum.reverse(skipped_rev)}
  end

  defp continues_previous?(current_group, page) do
    prev = List.last(current_group)

    cond do
      page["continuation"] ->
        true

      same_value?(prev["invoice_number"], page["invoice_number"]) and
          same_value?(prev["vendor_gstin"], page["vendor_gstin"]) ->
        true

      is_nil(page["invoice_number"]) and is_nil(page["vendor_gstin"]) and
          page["line_items"] == [] ->
        true

      true ->
        false
    end
  end

  defp same_value?(a, b), do: not is_nil(a) and not is_nil(b) and a == b

  defp build_invoice(group, index) do
    first = hd(group)
    line_items = Enum.flat_map(group, & &1["line_items"])

    taxable = line_items |> Enum.map(& &1["taxable_paise"]) |> Enum.sum()

    tax =
      Enum.reduce(line_items, %{"cgst" => 0, "sgst" => 0, "igst" => 0}, fn line, acc ->
        Map.merge(acc, line["tax_paise"], fn _k, a, b -> a + b end)
      end)

    printed_total =
      group |> Enum.map(& &1["printed_grand_total"]) |> Enum.reject(&is_nil/1) |> List.last()

    %{
      "id" => "inv_" <> String.pad_leading(to_string(index), 2, "0"),
      "pages" => Enum.map(group, & &1["page"]),
      "images" => group |> Enum.map(& &1["image"]) |> Enum.reject(&is_nil/1),
      "vendor_name" => first_present(group, "vendor_name"),
      "vendor_gstin" => first_present(group, "vendor_gstin"),
      "vendor_gstin_status" => first["vendor_gstin_status"],
      "vendor_address" => first_present(group, "vendor_address"),
      "invoice_number" => first_present(group, "invoice_number"),
      "invoice_date" => first_present(group, "invoice_date"),
      "delivery_address" => first_present(group, "delivery_address"),
      "line_items" => line_items,
      "taxable_paise" => taxable,
      "tax_paise" => tax,
      "total_paise" => printed_total_paise(printed_total, taxable, tax),
      "printed_total_paise" => printed_total && paise(printed_total),
      "confidence" => first["confidence"]
    }
  end

  defp printed_total_paise(nil, taxable, tax),
    do: taxable + tax["cgst"] + tax["sgst"] + tax["igst"]

  defp printed_total_paise(printed, _taxable, _tax), do: paise(printed)

  defp first_present(group, key), do: Enum.find_value(group, & &1[key])

  defp normalize_inum(nil), do: nil
  defp normalize_inum(value), do: value |> String.trim() |> String.upcase()

  defp strip_non_digits(nil), do: nil
  defp strip_non_digits(value), do: String.replace(value, ~r/\D/, "")

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp presence(value), do: value
end
