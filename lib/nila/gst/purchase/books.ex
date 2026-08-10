defmodule Nila.Gst.Purchase.Books do
  @moduledoc """
  Turns per-page purchase extraction artifacts into the books-side invoice
  contract consumed by `Nila.Gst.Purchase.Reconciliation` and `Nila.Gst.Purchase.Flags`.

  Pure: takes plain maps (decoded page artifacts), returns plain maps. Handles
  the realities of merged scan dumps: multi-page invoices (grouped by
  continuation flag or by same vendor GSTIN + invoice number on consecutive
  pages), GSTINs printed with separators (`33-AEWPH4158J-1Z3`), rupee floats,
  and mixed date formats.
  """

  alias Nila.Gst.Extraction.LineAmounts
  alias Nila.Gst.InvoiceNumber

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
        # The printed text, when it was there and could not be read as a date.
        # Never set alongside `invoice_date` — see `read_invoice_date/1`.
        "unreadable_invoice_date" => String.t() | nil,
        # Source field names whose amounts were printed but unreadable, counted
        # as zero in the sums above. `nil` when everything read.
        "unreadable_amounts" => [String.t()] | nil,
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

  # Returns `{date, unreadable_text}` — exactly one of the two is set.
  #
  # A date we cannot read is a question for the reviewer, not a `nil`. Dropping
  # the text made `invoice_date` indistinguishable from a bill that never
  # printed one, and `Reconciliation.dates_close?/3` returns false for a nil
  # date — so a single bad character silently withdrew date corroboration from
  # the match ladder, demoting the row to `needs_human` with nothing anywhere
  # saying why. The sales side has kept the text for exactly this reason since
  # `unreadable_invoice_date` was written; purchase never did.
  defp read_invoice_date(value) do
    case presence(value) do
      nil ->
        {nil, nil}

      %Date{} = date ->
        {date, nil}

      text ->
        case parse_date(to_string(text)) do
          %Date{} = date -> {date, nil}
          nil -> {nil, to_string(text)}
        end
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

  @doc """
  Converts a rupee number (float/int/string) to integer paise. Nil-safe.

  Both "absent" and "unreadable" collapse to `0` here. That is fine for the
  callers that only need a number to sum, and wrong for anyone deciding whether
  a figure was *read* — use `paise_or_error/1` for that.
  """
  def paise(value) do
    case paise_or_error(value) do
      {:ok, paise} -> paise
      _missing_or_unreadable -> 0
    end
  end

  @doc """
  Rupees to paise, keeping the three outcomes apart: `{:ok, paise}`,
  `:missing` (nothing printed) and `:unreadable` (something printed that is not
  a number).

  `paise/1` folds the last two into `0`, which reads downstream as a genuine
  zero. A line whose taxable value came off the scan as `"1,2SO.00"` became
  ₹0 inside an otherwise valid invoice, and `Flags.check_tax_arithmetic/3` then
  reported a line-vs-invoice mismatch — blaming the arithmetic for a character
  the OCR never read. The reviewer got sent to the wrong question.
  """
  def paise_or_error(nil), do: :missing
  def paise_or_error(value) when is_integer(value), do: {:ok, value * 100}
  def paise_or_error(value) when is_float(value), do: {:ok, round(value * 100)}

  def paise_or_error(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :missing
      trimmed -> parse_rupee_text(trimmed)
    end
  end

  def paise_or_error(_value), do: :unreadable

  # Currency marks are noise; anything else that is not part of a number means
  # the number was not read.
  #
  # The old rule deleted every character outside `[0-9.\-]` and parsed whatever
  # survived, which is two silent wrongs. `"Rs. 1,275.00"` kept the dot from
  # `Rs.`, became `".1275.00"`, failed `Float.parse` and was booked as ₹0 — a
  # rupee prefix, on a real bill, zeroing the line. And `"1,2SO.OO"` — an OCR
  # that read S for 5 and O for 0 — collapsed to `"12."` and was booked as ₹12,
  # a number small enough to look like a cheap item and never be questioned.
  # Both now say so instead.
  @currency_prefix ~r/^(rs\.?|inr|₹)\s*/i
  @grouping ~r/[\s,]/
  @number ~r/^-?\d+(\.\d+)?$/

  defp parse_rupee_text(trimmed) do
    cleaned =
      trimmed
      |> String.replace(@currency_prefix, "")
      |> String.replace(@grouping, "")

    cond do
      cleaned == "" ->
        :unreadable

      not Regex.match?(@number, cleaned) ->
        :unreadable

      true ->
        {number, ""} = Float.parse(cleaned)
        {:ok, round(number * 100)}
    end
  end

  defp normalize_page(artifact) do
    data = artifact["data"] || %{}
    seller = data["seller"] || %{}

    {gstin_status, gstin} = clean_gstin(seller["gstin"])
    {invoice_date, unreadable_date} = read_invoice_date(data["invoice_date"])

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
      "invoice_number" => data["invoice_number"] |> presence() |> InvoiceNumber.store(),
      "invoice_date" => invoice_date,
      "unreadable_invoice_date" => unreadable_date,
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

  # The four money fields are read through `paise_or_error/1` so an unreadable
  # one is named rather than folded into a zero nobody can tell from a real
  # one. The zero still goes into the sums — the invoice has to total to
  # something — but `unreadable_amounts` carries the evidence out to the flag.
  @line_amount_fields [
    {"cgst_amount", ["tax_paise", "cgst"]},
    {"sgst_amount", ["tax_paise", "sgst"]},
    {"igst_amount", ["tax_paise", "igst"]}
  ]

  defp normalize_line(line) do
    amounts = LineAmounts.normalize(line)

    read =
      @line_amount_fields
      |> Map.new(fn {source, _path} -> {source, paise_or_error(line[source])} end)
      |> Map.put("taxable_value", taxable_paise_or_error(line, amounts))

    unreadable =
      for {source, :unreadable} <- read, do: source

    %{
      "description" => presence(line["description"]),
      "hsn_sac" => line["hsn_sac"] |> presence() |> strip_non_digits(),
      "quantity" => line["quantity"],
      "unit_price_paise" => paise_or_nil(amounts.printed_unit_price),
      "printed_line_amount_paise" => paise_or_nil(amounts.printed_line_amount),
      "printed_taxable_value_paise" => paise_or_nil(amounts.printed_taxable_value),
      "line_amount_tax_inclusion" => amounts.line_amount_tax_inclusion,
      "discount_rate" => line["discount_rate"],
      "discount_paise" => paise_or_nil(line["discount_amount"]),
      "taxable_paise" => read_paise(read, "taxable_value"),
      "cgst_rate" => line["cgst_rate"],
      "sgst_rate" => line["sgst_rate"],
      "igst_rate" => line["igst_rate"],
      "tax_paise" => %{
        "cgst" => read_paise(read, "cgst_amount"),
        "sgst" => read_paise(read, "sgst_amount"),
        "igst" => read_paise(read, "igst_amount")
      },
      "unreadable_amounts" => if(unreadable == [], do: nil, else: Enum.sort(unreadable))
    }
  end

  defp taxable_paise_or_error(line, amounts) do
    cond do
      Map.has_key?(line, "printed_taxable_value") and
          not is_nil(line["printed_taxable_value"]) ->
        paise_or_error(line["printed_taxable_value"])

      not Map.has_key?(line, "printed_taxable_value") and
          not is_nil(line["taxable_value"]) ->
        paise_or_error(line["taxable_value"])

      amounts.line_amount_tax_inclusion in ~w(inclusive exclusive) and
          is_nil(amounts.taxable_value) ->
        line
        |> then(&(&1["printed_line_amount"] || &1["tax_inclusive_value"]))
        |> paise_or_error()
        |> missing_unless_unreadable()

      true ->
        paise_or_error(amounts.taxable_value)
    end
  end

  defp missing_unless_unreadable(:unreadable), do: :unreadable
  defp missing_unless_unreadable(_clean_or_missing), do: :missing

  defp read_paise(read, source) do
    case read[source] do
      {:ok, paise} -> paise
      _missing_or_unreadable -> 0
    end
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
    invoice_date = first_present(group, "invoice_date")

    # Only unreadable when no page of the invoice yielded a date: a continuation
    # page that printed nothing legible is not a defect if page 1 was clean.
    unreadable_date =
      if invoice_date, do: nil, else: first_present(group, "unreadable_invoice_date")

    unreadable_amounts =
      line_items
      |> Enum.flat_map(&(&1["unreadable_amounts"] || []))
      |> Enum.uniq()
      |> Enum.sort()

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
      "invoice_date" => invoice_date,
      "unreadable_invoice_date" => unreadable_date,
      "unreadable_amounts" => if(unreadable_amounts == [], do: nil, else: unreadable_amounts),
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

  defp strip_non_digits(nil), do: nil
  defp strip_non_digits(value), do: String.replace(value, ~r/\D/, "")

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp presence(value), do: value
end
