defmodule Nila.Gst.Filing.WinmanGstr1 do
  @moduledoc """
  Builds Winman GST 9.5.6 B2B import workbooks from Nila's effective GSTR-1.

  The bundled workbook is a vendor template, not business truth. This adapter
  fills only its B2B sheet and leaves every other GSTR-1 section empty.
  """

  alias Nila.Gst.Filing.WinmanGstr1.Package
  alias Nila.Gst.StateCodes

  @first_period ~D[2026-04-01]
  @last_period ~D[2027-03-01]
  @max_rows 995
  @tax_rates [0, 0.1, 0.25, 1, 1.5, 3, 5, 6, 7.5, 12, 18, 28, 40]
  @invalid_xml ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u

  @type projection :: %{required(:derived) => map(), required(:invoices) => [map()]}

  @doc "Whether the bundled Winman template supports this filing period."
  def supported_period?(period) do
    case period_date(period) do
      {:ok, date} ->
        Date.compare(date, @first_period) != :lt and Date.compare(date, @last_period) != :gt

      {:error, :invalid_period} ->
        false
    end
  end

  @doc "Builds a macro-enabled Winman workbook containing only B2B rows."
  @spec build(projection(), map(), String.t()) ::
          {:ok, binary()}
          | {:error, :invalid_period | :unsupported_period | :invalid_b2b_data | :too_many_rows}
  def build(%{derived: derived, invoices: invoices}, client, period) do
    with {:ok, date} <- period_date(period),
         :ok <- require_supported_period(date),
         :ok <- validate_client(client),
         {:ok, rows} <- b2b_rows(derived, invoices),
         :ok <- require_row_capacity(rows) do
      {:ok, Package.build(rows, title(client, period))}
    end
  end

  defp b2b_rows(derived, invoices) do
    names = recipient_names(invoices)

    derived["b2b"]
    |> List.wrap()
    |> Enum.flat_map(fn recipient ->
      for invoice <- recipient["inv"] || [],
          item <- invoice["itms"] || [],
          do: {recipient, invoice, item}
    end)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, rows} ->
      case b2b_row(entry, names) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, :invalid_b2b_data} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, :invalid_b2b_data} = error -> error
    end
  end

  defp b2b_row({recipient, invoice, item}, names) do
    details = item["itm_det"] || %{}
    gstin = normalize_gstin(recipient["ctin"])
    key = {gstin, invoice["inum"]}
    customer_name = Map.get(names, key)

    with {:ok, date} <- parse_date(invoice["idt"]),
         {:ok, state} <- winman_state(invoice["pos"]),
         :ok <- validate_values(gstin, customer_name, invoice, details) do
      {:ok,
       %{
         invoice_number: invoice["inum"],
         customer_name: customer_name,
         gstin: gstin,
         invoice_date: date,
         invoice_value: invoice["val"],
         tax_rate: details["rt"],
         taxable_value: details["txval"],
         igst: details["iamt"] || 0,
         cgst: details["camt"] || 0,
         sgst: details["samt"] || 0,
         cess: details["csamt"] || 0,
         state_of_supply: state,
         reverse_charge: if(invoice["rchrg"] == "Y", do: "Yes", else: "No")
       }}
    end
  end

  defp validate_values(gstin, customer_name, invoice, details) do
    numbers = [
      invoice["val"],
      details["rt"],
      details["txval"],
      details["iamt"] || 0,
      details["camt"] || 0,
      details["samt"] || 0,
      details["csamt"] || 0
    ]

    valid? =
      Nila.Gstin.valid?(gstin) and present?(invoice["inum"]) and
        String.length(invoice["inum"]) <= 16 and valid_text?(invoice["inum"]) and
        valid_optional_text?(customer_name) and invoice["rchrg"] in [nil, "N", "Y"] and
        details["rt"] in @tax_rates and Enum.all?(numbers, &nonnegative_number?/1)

    if valid?, do: :ok, else: {:error, :invalid_b2b_data}
  end

  defp validate_client(%{name: name}) do
    if present?(name) and valid_text?(name), do: :ok, else: {:error, :invalid_b2b_data}
  end

  defp validate_client(_client), do: {:error, :invalid_b2b_data}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_text?(value), do: is_binary(value) and not Regex.match?(@invalid_xml, value)
  defp valid_optional_text?(nil), do: true
  defp valid_optional_text?(value), do: valid_text?(value)
  defp nonnegative_number?(value), do: is_number(value) and value >= 0

  defp recipient_names(invoices) do
    Enum.reduce(invoices, %{}, fn invoice, names ->
      key = {normalize_gstin(invoice["buyer_gstin"]), invoice["invoice_number"]}

      if elem(key, 0) && elem(key, 1) do
        Map.put_new(names, key, invoice["buyer_name"])
      else
        names
      end
    end)
  end

  defp normalize_gstin(gstin) when is_binary(gstin), do: gstin |> String.trim() |> String.upcase()
  defp normalize_gstin(_gstin), do: nil

  defp parse_date(date) when is_binary(date) do
    with [day, month, year] <- String.split(date, "-"),
         {day, ""} <- Integer.parse(day),
         {month, ""} <- Integer.parse(month),
         {year, ""} <- Integer.parse(year),
         {:ok, parsed} <- Date.new(year, month, day) do
      {:ok, parsed}
    else
      _invalid -> {:error, :invalid_b2b_data}
    end
  end

  defp parse_date(_date), do: {:error, :invalid_b2b_data}

  defp winman_state(code) do
    name =
      case StateCodes.normalize_code(code) do
        "35" -> "Andaman & Nicobar Islands"
        "26" -> "Dadra and Nagar Haveli & Daman and Diu"
        "96" -> "State outside India"
        "97" -> "Other Territory"
        normalized -> StateCodes.name_for(normalized)
      end

    if name, do: {:ok, name}, else: {:error, :invalid_b2b_data}
  end

  defp title(client, period) do
    year = period |> String.slice(0, 4) |> String.to_integer()
    start_year = if String.slice(period, 5, 2) >= "04", do: year, else: year - 1
    short_year = rem(start_year, 100) |> Integer.to_string() |> String.pad_leading(2, "0")

    next_short_year =
      rem(start_year + 1, 100) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{client.name}_#{short_year}-#{next_short_year}.wgst - GST - F.Y. : #{start_year}-#{start_year + 1}"
  end

  defp period_date(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(year, month, 1) do
      {:ok, date}
    else
      _invalid -> {:error, :invalid_period}
    end
  end

  defp period_date(_period), do: {:error, :invalid_period}

  defp require_supported_period(date) do
    if Date.compare(date, @first_period) != :lt and Date.compare(date, @last_period) != :gt,
      do: :ok,
      else: {:error, :unsupported_period}
  end

  defp require_row_capacity(rows) do
    if length(rows) <= @max_rows, do: :ok, else: {:error, :too_many_rows}
  end
end
