defmodule Nila.Gst.Sales.RspValuation do
  @moduledoc """
  Resolves tax in a section report whose 40% tobacco HSN summary supplies the
  tax basis that its invoice-rate rows omit. The commercial taxable value is
  not the RSP tax base. Source values remain in return_report_values.
  """

  alias Nila.Gst.Money

  @effective ~D[2026-02-01]
  @tolerance_paise 100
  @heads ~w(cgst_amount sgst_amount igst_amount)

  @doc "Removes a previous derived view before corrections and recalculation."
  def reset(invoice) do
    valuation = invoice["tax_valuation"]

    if is_map(valuation) and valuation["basis"] == "rsp" do
      lines =
        invoice
        |> Map.get("line_items", [])
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          source = Enum.at(invoice["return_report_values"] || [], index)

          applied = Enum.at(valuation["applied_tax"] || [], index)

          if source && applied &&
               line["tax_amount_basis"] in ~w(invoice_value_residual unresolved_rsp) do
            ["cgst_amount", "sgst_amount", "igst_amount"]
            |> Enum.reduce(line, fn key, current ->
              source_key =
                %{"cgst_amount" => "camt", "sgst_amount" => "samt", "igst_amount" => "iamt"}[key]

              if key not in List.wrap(current["corrected_tax_fields"]) and
                   current[key] == applied[key],
                 do: Map.put(current, key, source[source_key]),
                 else: current
            end)
            |> Map.delete("tax_amount_basis")
          else
            Map.delete(line, "tax_amount_basis")
          end
        end)

      invoice |> Map.put("line_items", lines) |> Map.delete("tax_valuation")
    else
      invoice
    end
  end

  def apply(invoices, reports) do
    invoices = Enum.map(invoices, &reset/1)

    by_dump =
      invoices
      |> Enum.group_by(& &1["return_report_dump_id"])
      |> Enum.flat_map(fn {dump_id, members} ->
        matching =
          Enum.filter(reports, fn report ->
            report["dump_id"] == dump_id and report["format"] == "standard_gstr1_sections"
          end)

        if matching == [], do: members, else: resolve(members, matching)
      end)
      |> Map.new(&{&1["id"], &1})

    Enum.map(invoices, &Map.fetch!(by_dump, &1["id"]))
  end

  defp resolve(invoices, reports) do
    hsn_rows =
      for report <- reports,
          report["format"] == "standard_gstr1_sections",
          row <- report["rows"] || [],
          row["section"] == "hsn_b2b" and num(row["values"]["rate"]) == 40,
          do: row

    registered = Enum.filter(invoices, &registered_40?/1)

    eligible =
      hsn_rows != [] and Enum.all?(hsn_rows, &covered_hsn?/1) and
        hsn_rows |> Enum.map(& &1["source_filename"]) |> Enum.uniq() |> length() == 1

    b2c_hsn_rows =
      for report <- reports,
          row <- report["rows"] || [],
          row["section"] == "hsn_b2c" and num(row["values"]["rate"]) == 40,
          do: row

    b2c_hsn? = b2c_hsn_rows != [] and Enum.all?(b2c_hsn_rows, &covered_hsn?/1)

    group_valid? =
      eligible and registered != [] and Enum.all?(registered, &safe_residual?/1) and
        no_unmatched_registered_40?(invoices, registered) and
        close?(net(registered, &taxable_paise/1), hsn_total(hsn_rows, "txval")) and
        close?(net(registered, &residual_paise/1), hsn_tax(hsn_rows)) and
        close?(net(registered, &candidate_cgst_paise/1), hsn_total(hsn_rows, "camt")) and
        close?(net(registered, &candidate_sgst_paise/1), hsn_total(hsn_rows, "samt"))

    difference =
      if hsn_rows == [],
        do: nil,
        else: Money.rupee_number((net(registered, &residual_paise/1) - hsn_tax(hsn_rows)) / 100)

    Enum.map(invoices, fn invoice ->
      cond do
        registered_40?(invoice) and group_valid? ->
          derived(invoice, difference)

        registered_with_40?(invoice) and eligible ->
          unresolved(invoice)

        unregistered_with_40?(invoice) and b2c_hsn? ->
          unresolved(invoice)

        true ->
          invoice
      end
    end)
  end

  defp registered_40?(invoice),
    do: invoice["return_report_section"] in ~w(B2B CDNR) and source_40?(invoice)

  defp registered_with_40?(invoice),
    do:
      invoice["return_report_section"] in ~w(B2B CDNR) and with_40?(invoice) and
        effective_date?(invoice)

  defp unregistered_with_40?(invoice),
    do:
      invoice["return_report_section"] in ~w(B2CL CDNUR) and with_40?(invoice) and
        effective_date?(invoice)

  defp effective_date?(invoice) do
    case invoice["invoice_date"] do
      %Date{} = date -> Date.compare(date, @effective) != :lt
      date when is_binary(date) -> source_date?(date)
      _ -> false
    end
  end

  defp with_40?(invoice),
    do: Enum.any?(List.wrap(invoice["return_report_values"]), &(num(&1["rate"]) == 40))

  defp source_40?(invoice) do
    case List.wrap(invoice["return_report_values"]) do
      [value | rest] ->
        keys = ~w(rate date value txval pos camt samt iamt csamt number buyer_gstin)

        Enum.all?(rest, &(Map.take(&1, keys) == Map.take(value, keys))) and
          num(value["rate"]) == 40 and source_date?(value["date"])

      _ ->
        false
    end
  end

  defp no_unmatched_registered_40?(invoices, registered) do
    ids = MapSet.new(registered, & &1["id"])

    Enum.all?(invoices, fn invoice ->
      invoice["return_report_section"] not in ~w(B2B CDNR) or not with_40?(invoice) or
        MapSet.member?(ids, invoice["id"])
    end)
  end

  defp source_date?(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.compare(parsed, @effective) != :lt
      _ -> false
    end
  end

  defp source_date?(_), do: false

  defp covered_hsn?(row) do
    values = row["values"]
    code = to_string(values["hsn_sc"] || "") |> String.replace(~r/\D/, "")

    (String.starts_with?(code, "2402") or code in ~w(21069020 24041100 24041900)) and
      num(values["csamt"]) == 0 and num(values["iamt"]) == 0 and
      is_number(values["camt"]) and is_number(values["samt"]) and
      abs(Money.paise(values["camt"]) - Money.paise(values["samt"])) <= 1
  end

  defp safe_residual?(invoice) do
    case {invoice["line_items"], invoice["return_report_values"]} do
      {[line], [source | _]} ->
        residual = residual_paise(invoice)

        invoice["document_type"] in ~w(invoice credit_note debit_note) and
          Money.paise(invoice["printed_grand_total"]) == Money.paise(source["value"]) and
          same_date?(invoice["invoice_date"], source["date"]) and
          invoice["place_of_supply"] == String.slice(source["pos"] || "", 0, 2) and
          invoice["place_of_supply"] == String.slice(invoice["seller_gstin"] || "", 0, 2) and
          num(line["taxable_value"]) == num(source["txval"]) and
          num(line["cgst_rate"]) + num(line["sgst_rate"]) + num(line["igst_rate"]) == 40 and
          num(line["igst_rate"]) == 0 and num(source["iamt"]) == 0 and
          candidate_tax_valid?(invoice, source) and
          num(source["csamt"]) == 0 and source["etin"] in [nil, ""] and
          source["invoice_type"] in [nil, "R"] and
          invoice["reverse_charge"] != true and invoice["tax_payment"] != "without_payment" and
          Enum.all?(
            ~w(printed_additional_charges printed_rounding_adjustment printed_discount_amount),
            &(num(invoice[&1]) == 0)
          ) and
          residual > 0 and is_binary(invoice["seller_gstin"])

      _ ->
        false
    end
  end

  defp candidate_tax_valid?(invoice, source) do
    [line] = invoice["line_items"]

    source_tax_unchanged?(line, source) or
      (is_number(line["cgst_amount"]) and is_number(line["sgst_amount"]) and
         Money.paise(line["igst_amount"]) == 0 and
         abs(Money.paise(line["cgst_amount"]) - Money.paise(line["sgst_amount"])) <= 1 and
         Money.paise(line["cgst_amount"]) + Money.paise(line["sgst_amount"]) ==
           residual_paise(invoice))
  end

  defp candidate_cgst_paise(invoice) do
    [line] = invoice["line_items"]
    source = hd(invoice["return_report_values"])

    if source_tax_unchanged?(line, source),
      do: div(residual_paise(invoice), 2),
      else: Money.paise(line["cgst_amount"])
  end

  defp candidate_sgst_paise(invoice) do
    [line] = invoice["line_items"]
    source = hd(invoice["return_report_values"])

    if source_tax_unchanged?(line, source),
      do: residual_paise(invoice) - div(residual_paise(invoice), 2),
      else: Money.paise(line["sgst_amount"])
  end

  defp same_date?(%Date{} = date, source), do: Date.to_iso8601(date) == source
  defp same_date?(date, source), do: date == source

  defp source_tax_unchanged?(line, source) do
    List.wrap(line["corrected_tax_fields"]) == [] and
      Enum.all?(
        [{"cgst_amount", "camt"}, {"sgst_amount", "samt"}, {"igst_amount", "iamt"}],
        fn {line_key, source_key} ->
          Money.paise(line[line_key]) == Money.paise(source[source_key])
        end
      )
  end

  defp derived(invoice, difference) do
    [line] = invoice["line_items"]
    source = hd(invoice["return_report_values"])
    manual? = not source_tax_unchanged?(line, source)

    line =
      if manual? do
        Map.put(line, "tax_amount_basis", "reviewer_entered")
      else
        cgst_paise = div(residual_paise(invoice), 2)
        sgst_paise = residual_paise(invoice) - cgst_paise

        line
        |> Map.merge(%{
          "cgst_amount" => cgst_paise / 100,
          "sgst_amount" => sgst_paise / 100,
          "igst_amount" => 0.0
        })
        |> Map.put("tax_amount_basis", "invoice_value_residual")
      end

    invoice
    |> Map.put("line_items", [line])
    |> Map.put("tax_valuation", %{
      "basis" => "rsp",
      "method" => if(manual?, do: "reviewer_entered", else: "invoice_value_residual"),
      "status" => "derived",
      "reconciliation" => %{"scope" => "hsn_b2b_net", "difference" => difference},
      "applied_tax" => [Map.take(line, @heads)]
    })
  end

  defp unresolved(invoice) do
    invoice
    |> Map.update!("line_items", fn lines ->
      Enum.with_index(lines)
      |> Enum.map(fn {line, index} ->
        source = Enum.at(invoice["return_report_values"], index)

        if source && num(source["rate"]) == 40 do
          retained =
            Enum.filter(@heads, fn key ->
              source_key =
                %{"cgst_amount" => "camt", "sgst_amount" => "samt", "igst_amount" => "iamt"}[key]

              key in List.wrap(line["corrected_tax_fields"]) or
                Money.paise(line[key]) != Money.paise(source[source_key])
            end)

          line
          |> Map.merge(
            Map.new(@heads, fn key -> {key, if(key in retained, do: line[key], else: nil)} end)
          )
          |> Map.put(
            "tax_amount_basis",
            if(retained == [], do: "unresolved_rsp", else: "reviewer_entered")
          )
        else
          line
        end
      end)
    end)
    |> then(fn result ->
      Map.put(result, "tax_valuation", %{
        "basis" => "rsp",
        "status" => "unresolved",
        "applied_tax" => Enum.map(result["line_items"], &Map.take(&1, @heads))
      })
    end)
  end

  defp net(invoices, amount) do
    Enum.sum(
      Enum.map(invoices, fn invoice ->
        sign = if invoice["document_type"] == "credit_note", do: -1, else: 1
        sign * amount.(invoice)
      end)
    )
  end

  defp taxable_paise(invoice), do: Money.paise(hd(invoice["line_items"])["taxable_value"])

  defp residual_paise(invoice),
    do: Money.paise(invoice["printed_grand_total"]) - taxable_paise(invoice)

  defp hsn_total(rows, key), do: Enum.sum(Enum.map(rows, &Money.paise(&1["values"][key])))

  defp hsn_tax(rows),
    do:
      Enum.sum(
        Enum.map(
          rows,
          &(Money.paise(&1["values"]["camt"]) + Money.paise(&1["values"]["samt"]) +
              Money.paise(&1["values"]["iamt"]))
        )
      )

  defp close?(left, right), do: abs(left - right) <= @tolerance_paise
  defp num(value) when is_number(value), do: value
  defp num(_), do: 0
end
