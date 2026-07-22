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
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      {:error, _reason} -> parse_printed_date(value)
    end
  end

  defp parse_printed_date(value) do
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
      "source_pages" => artifact["source_pages"] || [artifact["page"]],
      "source_attribution" => artifact["source_attribution"],
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
      "printed_subtotal_before_discount" => data["printed_subtotal_before_discount"],
      "printed_discount_amount" => data["printed_discount_amount"],
      "printed_total_taxable" => data["printed_total_taxable"],
      "printed_cgst" => data["printed_cgst"],
      "printed_sgst" => data["printed_sgst"],
      "printed_igst" => data["printed_igst"],
      "printed_total_tax" => data["printed_total_tax"],
      "printed_additional_charges" => data["printed_additional_charges"],
      "printed_rounding_adjustment" => data["printed_rounding_adjustment"],
      "printed_grand_total" => data["printed_grand_total"],
      "confidence" => artifact["confidence"]
    }
  end

  defp normalize_line(line) do
    %{
      "description" => presence(line["description"]),
      "hsn_sac" => line["hsn_sac"] |> presence() |> strip_non_digits(),
      "quantity" => line["quantity"],
      "unit_price_paise" => paise_or_nil(line["unit_price"]),
      "discount_rate" => line["discount_rate"],
      "discount_paise" => paise_or_nil(line["discount_amount"]),
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

    line_taxable = line_items |> Enum.map(& &1["taxable_paise"]) |> Enum.sum()

    line_tax =
      Enum.reduce(line_items, %{"cgst" => 0, "sgst" => 0, "igst" => 0}, fn line, acc ->
        Map.merge(acc, line["tax_paise"], fn _k, a, b -> a + b end)
      end)

    printed = printed_breakdown(group)
    {taxable, tax, arithmetic_basis} = invoice_amounts(line_taxable, line_tax, printed)

    %{
      "id" => "inv_" <> String.pad_leading(to_string(index), 2, "0"),
      "pages" => group |> Enum.flat_map(& &1["source_pages"]) |> Enum.uniq(),
      "source_attribution" => first["source_attribution"],
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
      "total_paise" => invoice_total_paise(printed, arithmetic_basis, taxable, tax),
      "printed_total_paise" => printed.grand_total,
      "printed_taxable_paise" => printed.taxable,
      "printed_discount_paise" => printed.discount,
      "arithmetic_basis" => arithmetic_basis,
      "confidence" => first["confidence"]
    }
  end

  defp printed_breakdown(group) do
    %{
      subtotal: last_paise(group, "printed_subtotal_before_discount"),
      discount: last_paise(group, "printed_discount_amount"),
      taxable: last_paise(group, "printed_total_taxable"),
      cgst: last_paise(group, "printed_cgst"),
      sgst: last_paise(group, "printed_sgst"),
      igst: last_paise(group, "printed_igst"),
      total_tax: last_paise(group, "printed_total_tax"),
      charges: last_paise(group, "printed_additional_charges"),
      rounding: last_paise(group, "printed_rounding_adjustment"),
      grand_total: last_paise(group, "printed_grand_total")
    }
  end

  defp invoice_amounts(line_taxable, line_tax, printed) do
    cond do
      reconciled_printed_breakdown?(printed) ->
        {printed.taxable, printed_tax(printed), "printed_reconciled"}

      reconciled_printed_final?(printed) ->
        {printed.taxable, printed_tax(printed), "printed_final_reconciled"}

      true ->
        {line_taxable, line_tax, "line_items"}
    end
  end

  defp reconciled_printed_breakdown?(printed) do
    discount = printed.discount || 0

    reconciled_printed_final?(printed) and not is_nil(printed.subtotal) and discount >= 0 and
      close_paise?(printed.subtotal - discount, printed.taxable)
  end

  defp reconciled_printed_final?(printed) do
    tax_components = [printed.cgst, printed.sgst, printed.igst]

    (is_nil(printed.discount) or printed.discount >= 0) and not is_nil(printed.taxable) and
      not is_nil(printed.total_tax) and not is_nil(printed.grand_total) and
      Enum.any?(tax_components, &(not is_nil(&1))) and
      close_paise?(Enum.sum(Enum.map(tax_components, &(&1 || 0))), printed.total_tax) and
      close_paise?(
        printed.taxable + printed.total_tax + (printed.charges || 0) + (printed.rounding || 0),
        printed.grand_total
      )
  end

  defp printed_tax(printed) do
    %{
      "cgst" => printed.cgst || 0,
      "sgst" => printed.sgst || 0,
      "igst" => printed.igst || 0
    }
  end

  defp close_paise?(left, right), do: abs(left - right) <= 2

  defp last_paise(group, key) do
    group
    |> Enum.map(& &1[key])
    |> Enum.reject(&is_nil/1)
    |> List.last()
    |> paise_or_nil()
  end

  defp paise_or_nil(nil), do: nil
  defp paise_or_nil(value), do: paise(value)

  defp invoice_total_paise(printed, arithmetic_basis, _taxable, _tax)
       when arithmetic_basis in ["printed_reconciled", "printed_final_reconciled"],
       do: printed.grand_total

  defp invoice_total_paise(printed, "line_items", taxable, tax) do
    derived = taxable + tax["cgst"] + tax["sgst"] + tax["igst"]

    if structured_breakdown_present?(printed), do: derived, else: printed.grand_total || derived
  end

  defp structured_breakdown_present?(printed) do
    Enum.any?(
      [
        printed.subtotal,
        printed.discount,
        printed.taxable,
        printed.cgst,
        printed.sgst,
        printed.igst,
        printed.total_tax,
        printed.charges,
        printed.rounding
      ],
      &(not is_nil(&1))
    )
  end

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
