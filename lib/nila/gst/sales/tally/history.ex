defmodule Nila.Gst.Sales.Tally.History do
  @moduledoc "Conservative proposals from dated ledger settings and earlier completed sales."
  import Ecto.Query
  alias Nila.{Repo, TallyMappings}
  alias Nila.TallyDevices.{SyncedVoucher, SyncRun}

  def load(org_id, company_id, period, ledgers) do
    {:ok, cutoff} = Date.from_iso8601(period <> "-01")

    vouchers =
      Repo.all(
        from v in SyncedVoucher,
          join: run in SyncRun,
          on: run.id == v.last_seen_sync_id,
          where:
            v.org_id == ^org_id and v.company_id == ^company_id and
              v.voucher_type == "Sales" and v.date < ^cutoff and run.status == "succeeded" and
              run.org_id == ^org_id and run.company_id == ^company_id,
          order_by: v.date
      )

    build(ledgers, vouchers)
  end

  def build(ledgers, vouchers) do
    taxes =
      Map.new(~w(cgst sgst igst), fn head ->
        {head, Enum.filter(ledgers, &TallyMappings.tax_ledger_for_head?(&1, head))}
      end)

    heads_by_name =
      Enum.reduce(taxes, %{}, fn {head, choices}, acc ->
        Enum.reduce(choices, acc, fn ledger, acc ->
          Map.update(acc, ledger.name, [head], &[head | &1])
        end)
      end)

    %{
      sales_ledgers: Enum.filter(ledgers, &TallyMappings.sales_ledger?/1),
      party_ledgers: Enum.filter(ledgers, &TallyMappings.party_ledger?/1),
      tax_ledgers: taxes,
      vouchers: vouchers,
      usage:
        Enum.map(vouchers, fn voucher ->
          entries =
            List.wrap(voucher.data["ledger_entries"]) |> Enum.filter(&positive?(&1["amount"]))

          %{
            gstin: voucher.data["party_gstin"],
            ledgers: MapSet.new(entries, & &1["ledger_name"]),
            heads:
              entries
              |> Enum.flat_map(&Map.get(heads_by_name, &1["ledger_name"], []))
              |> Enum.uniq()
              |> Enum.sort()
          }
        end)
    }
  end

  def sales(history, invoice, line) do
    day =
      case invoice["invoice_date"] do
        %Date{} = date -> date
        value -> Nila.Gst.Dates.parse_date(value)
      end

    heads = heads(line)

    candidates =
      Enum.filter(history.sales_ledgers, fn ledger ->
        settings_match?(ledger.data, line, day)
      end)

    supported =
      Enum.map(candidates, fn ledger ->
        gstin = invoice["buyer_gstin"]

        rows =
          if is_binary(gstin) and String.trim(gstin) != "",
            do: usage(history, ledger, heads, gstin),
            else: []

        {ledger, rows}
      end)
      |> Enum.filter(fn {_, rows} -> rows != [] end)

    case supported do
      [{ledger, rows}] ->
        result(
          ledger,
          nil,
          "HSN and rates match; used in #{length(rows)} earlier sales for this GSTIN.",
          length(rows)
        )

      _ ->
        suggestion = if length(candidates) == 1, do: hd(candidates)

        result(
          nil,
          suggestion,
          if(suggestion,
            do: "HSN and rates match. Confirm first use for this party.",
            else: "No unique ledger supported by HSN, rates and earlier sales."
          ),
          0
        )
    end
  end

  def tax(history, head, rate) do
    supported =
      for ledger <- Map.get(history.tax_ledgers, head, []),
          equal?(ledger.data["rate_of_tax"], rate),
          rows = usage(history, ledger, nil, nil),
          rows != [],
          do: {ledger, rows}

    case supported do
      [{ledger, rows}] ->
        result(
          ledger,
          nil,
          "Duty head and rate match; used in #{length(rows)} earlier sales.",
          length(rows)
        )

      _ ->
        result(
          nil,
          nil,
          "No unique sales tax ledger supported by duty head, rate and earlier sales.",
          0
        )
    end
  end

  def tax_rate_matches?(ledger, head, rate),
    do:
      TallyMappings.tax_ledger_for_head?(ledger, head) and
        equal?(ledger.data["rate_of_tax"], rate)

  def rates(lines, head) do
    lines
    |> Enum.filter(&positive?(&1[head <> "_amount"]))
    |> Enum.map(&decimal(&1[head <> "_rate"]))
    |> Enum.uniq_by(&Decimal.to_string(Decimal.normalize(&1)))
  end

  defp result(ledger, suggestion, basis, count),
    do: %{ledger: ledger, suggestion: suggestion, basis: basis, history_count: count}

  defp settings_match?(_data, _line, nil), do: false

  defp settings_match?(data, line, day) do
    with hsn when is_map(hsn) <- dated(data["hsn_details"], day),
         true <- hsn["source"] == "Specify Details Here",
         true <- to_string(hsn["hsnCode"]) == to_string(line["hsn_sac"]),
         gst when is_map(gst) <- dated(data["gst_details"], day),
         true <- gst["sourceOfGSTDetails"] == "Specify Details Here",
         [state] <- gst["stateWiseDetails"],
         true <- state["stateName"] == "Any" do
      rates =
        Map.new(
          List.wrap(state["gstRateDetails"]),
          &{normalize_head(&1["dutyHead"]), &1["gstRate"]}
        )

      heads(line) != [] and Enum.all?(heads(line), &equal?(rates[&1], line[&1 <> "_rate"]))
    else
      _ -> false
    end
  end

  defp dated(records, day) do
    eligible =
      List.wrap(records)
      |> Enum.filter(fn record ->
        case Date.from_iso8601(String.slice(to_string(record["applicableFrom"]), 0, 10)) do
          {:ok, date} -> Date.compare(date, day) != :gt
          _ -> false
        end
      end)

    case Enum.sort_by(eligible, & &1["applicableFrom"], :desc) do
      [] ->
        nil

      [first | rest] ->
        if Enum.any?(rest, &(&1["applicableFrom"] == first["applicableFrom"])),
          do: nil,
          else: first
    end
  end

  defp usage(history, ledger, heads, gstin) do
    Enum.filter(history.usage, fn voucher ->
      (is_nil(gstin) or
         (is_binary(gstin) and gstin != "" and voucher.gstin == gstin)) and
        (is_nil(heads) or voucher.heads == heads) and
        MapSet.member?(voucher.ledgers, ledger.name)
    end)
  end

  defp heads(line), do: Enum.filter(~w(cgst sgst igst), &positive?(line[&1 <> "_amount"]))

  defp normalize_head(value),
    do: value |> to_string() |> String.downcase() |> String.replace("sgst/utgst", "sgst")

  defp positive?(value), do: Decimal.compare(decimal(value), Decimal.new(0)) == :gt
  defp equal?(nil, _), do: false
  defp equal?(_, nil), do: false
  defp equal?(a, b), do: Decimal.equal?(decimal(a), decimal(b))

  defp decimal(value) do
    case Decimal.parse(to_string(value || 0)) do
      {number, ""} -> number
      _ -> Decimal.new(0)
    end
  end
end
