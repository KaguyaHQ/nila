defmodule Nila.Banking.Tally do
  @moduledoc """
  Builds compact TallyPrime Payment and Receipt vouchers from a reconciled
  bank statement. Counter-postings land in a generated Suspense ledger; the
  bank ledger name must match the ledger already present in Tally.
  """

  @invalid_xml ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u

  @spec build(map(), keyword()) ::
          {:ok, binary()} | {:error, :invalid_statement | :no_transactions}
  def build(statement, opts \\ []) do
    ledger =
      opts |> Keyword.get(:bank_ledger_name, field(statement, :bank_ledger_name)) |> clean()

    from = Keyword.get(opts, :from, field(statement, :statement_from))
    to = Keyword.get(opts, :to, field(statement, :statement_to))

    with true <- field(statement, :status) == "ready",
         true <- valid_text?(ledger),
         %Date{} = from <- date(from),
         %Date{} = to <- date(to),
         true <- Date.compare(from, to) != :gt,
         transactions when is_list(transactions) <- field(statement, :transactions),
         [_first | _rest] = selected <- in_range(transactions, from, to) do
      messages = [suspense_ledger() | Enum.map(selected, &voucher(&1, statement, ledger))]
      {:ok, envelope(messages)}
    else
      [] -> {:error, :no_transactions}
      _invalid -> {:error, :invalid_statement}
    end
  end

  defp voucher(transaction, statement, bank_ledger) do
    withdrawal = integer(transaction, "withdrawal_paise")
    deposit = integer(transaction, "deposit_paise")
    {voucher_type, suspense_amount} = voucher_amount(withdrawal, deposit)
    bank_amount = -suspense_amount
    date = transaction |> value("date") |> date()
    date_text = Calendar.strftime(date, "%Y%m%d")
    narration = clean(value(transaction, "narration"))
    reference = clean(value(transaction, "reference")) || ""
    remote_id = remote_id(statement, transaction)

    [
      "<TALLYMESSAGE xmlns:UDF=\"TallyUDF\">",
      "<VOUCHER REMOTEID=\"",
      remote_id,
      "\" VCHTYPE=\"",
      voucher_type,
      "\" ACTION=\"Create\" OBJVIEW=\"Accounting Voucher View\">",
      tag("DATE", date_text),
      tag("GUID", remote_id),
      tag("VOUCHERTYPENAME", voucher_type),
      tag("NARRATION", narration),
      tag("PARTYLEDGERNAME", bank_ledger),
      tag("EFFECTIVEDATE", date_text),
      tag("PERSISTEDVIEW", "Accounting Voucher View"),
      tag("ISINVOICE", "No"),
      ledger_entry("Suspense", suspense_amount, false),
      bank_entry(bank_ledger, bank_amount, date_text, reference),
      "</VOUCHER></TALLYMESSAGE>"
    ]
  end

  defp voucher_amount(withdrawal, _deposit) when withdrawal != 0,
    do: {"Payment", -withdrawal}

  defp voucher_amount(_withdrawal, deposit), do: {"Receipt", deposit}

  defp ledger_entry(name, amount, party?) do
    [
      "<ALLLEDGERENTRIES.LIST>",
      tag("LEDGERNAME", name),
      tag("ISDEEMEDPOSITIVE", if(amount < 0, do: "Yes", else: "No")),
      tag("ISPARTYLEDGER", if(party?, do: "Yes", else: "No")),
      tag("AMOUNT", money(amount)),
      "</ALLLEDGERENTRIES.LIST>"
    ]
  end

  defp bank_entry(name, amount, date, reference) do
    [
      "<ALLLEDGERENTRIES.LIST>",
      tag("LEDGERNAME", name),
      tag("ISDEEMEDPOSITIVE", if(amount < 0, do: "Yes", else: "No")),
      tag("ISPARTYLEDGER", "Yes"),
      tag("AMOUNT", money(amount)),
      "<BANKALLOCATIONS.LIST>",
      tag("DATE", date),
      tag("INSTRUMENTDATE", date),
      tag("TRANSACTIONTYPE", "Cheque"),
      tag("PAYMENTFAVOURING", "Suspense"),
      tag("INSTRUMENTNUMBER", reference),
      tag("PAYMENTMODE", "Transacted"),
      tag("BANKPARTYNAME", "Suspense"),
      tag("AMOUNT", money(amount)),
      "</BANKALLOCATIONS.LIST>",
      "</ALLLEDGERENTRIES.LIST>"
    ]
  end

  defp suspense_ledger do
    [
      "<TALLYMESSAGE xmlns:UDF=\"TallyUDF\">",
      "<LEDGER NAME=\"Suspense\" ACTION=\"Create\">",
      tag("NAME", "Suspense"),
      tag("PARENT", "Suspense A/c"),
      tag("ISBILLWISEON", "No"),
      "</LEDGER></TALLYMESSAGE>"
    ]
  end

  defp envelope(messages) do
    IO.iodata_to_binary([
      "<ENVELOPE><HEADER><TALLYREQUEST>Import Data</TALLYREQUEST></HEADER>",
      "<BODY><IMPORTDATA><REQUESTDESC><REPORTNAME>All Masters</REPORTNAME>",
      "<STATICVARIABLES><SVOVERWRITEIMPVCH>Yes</SVOVERWRITEIMPVCH></STATICVARIABLES>",
      "</REQUESTDESC><REQUESTDATA>",
      messages,
      "</REQUESTDATA></IMPORTDATA></BODY></ENVELOPE>"
    ])
  end

  defp in_range(transactions, from, to) do
    Enum.filter(transactions, fn transaction ->
      case date(value(transaction, "date")) do
        %Date{} = transaction_date ->
          Date.compare(transaction_date, from) != :lt and
            Date.compare(transaction_date, to) != :gt

        nil ->
          false
      end
    end)
  end

  defp remote_id(statement, transaction) do
    identity =
      Enum.join(
        [
          "nila-bank",
          field(statement, :id) || field(statement, :source_key),
          value(transaction, "id") || value(transaction, "ordinal")
        ],
        "|"
      )

    "nila-bank-" <> Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end

  defp field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp integer(map, key) do
    case value(map, key) do
      value when is_integer(value) -> value
      _missing -> 0
    end
  end

  defp date(%Date{} = date), do: date

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp date(_value), do: nil

  defp valid_text?(value),
    do: is_binary(value) and value != "" and not Regex.match?(@invalid_xml, value)

  defp clean(nil), do: nil
  defp clean(value), do: value |> to_string() |> String.trim()

  defp money(paise) do
    sign = if paise < 0, do: "-", else: ""
    absolute = abs(paise)
    rupees = div(absolute, 100)
    cents = absolute |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> Integer.to_string(rupees) <> "." <> cents
  end

  defp tag(name, value), do: ["<", name, ">", xml(to_string(value || "")), "</", name, ">"]

  defp xml(value) do
    value
    |> String.replace(@invalid_xml, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
