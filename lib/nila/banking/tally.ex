defmodule Nila.Banking.Tally do
  @moduledoc """
  Builds compact TallyPrime Payment, Receipt, and Contra vouchers for connector delivery.
  """

  @invalid_xml ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u

  @doc "Builds one deterministic voucher for connector delivery."
  def build_transaction(statement, transaction, bank_ledger, counter_ledger)
      when is_binary(bank_ledger) and is_binary(counter_ledger) do
    with true <- field(statement, :status) == "ready",
         true <- valid_text?(clean(bank_ledger)),
         true <- valid_text?(clean(counter_ledger)),
         type when type in ~w(payment receipt contra_withdrawal contra_deposit) <-
           field(transaction, :transaction_type),
         company when is_binary(company) and company != "" <- company_name(statement),
         %Date{} <- date(field(transaction, :date)) do
      {:ok,
       connector_envelope(
         [voucher(transaction, statement, clean(bank_ledger), clean(counter_ledger), type)],
         company
       )}
    else
      _ -> {:error, :invalid_transaction}
    end
  end

  defp voucher(transaction, statement, bank_ledger, counter_ledger, transaction_type) do
    withdrawal = integer_field(transaction, :withdrawal_paise)
    deposit = integer_field(transaction, :deposit_paise)
    {voucher_type, counter_amount} = typed_voucher_amount(transaction_type, withdrawal, deposit)
    bank_amount = -counter_amount
    date = transaction |> field(:date) |> date()
    date_text = Calendar.strftime(date, "%Y%m%d")
    narration = clean(field(transaction, :narration))
    reference = clean(field(transaction, :reference)) || ""
    remote_alt_guid = remote_alt_guid(statement, transaction)

    [
      "<TALLYMESSAGE xmlns:UDF=\"TallyUDF\">",
      "<VOUCHER VCHTYPE=\"",
      voucher_type,
      "\" ACTION=\"Create\" OBJVIEW=\"Accounting Voucher View\">",
      tag("REMOTEALTGUID", remote_alt_guid),
      tag("DATE", date_text),
      tag("VOUCHERTYPENAME", voucher_type),
      tag("NARRATION", narration),
      tag("PARTYLEDGERNAME", bank_ledger),
      tag("EFFECTIVEDATE", date_text),
      tag("PERSISTEDVIEW", "Accounting Voucher View"),
      tag("ISINVOICE", "No"),
      ledger_entry(counter_ledger, counter_amount, false),
      bank_entry(bank_ledger, counter_ledger, bank_amount, date_text, reference),
      "</VOUCHER></TALLYMESSAGE>"
    ]
  end

  defp typed_voucher_amount(type, withdrawal, _deposit)
       when type in ~w(payment contra_withdrawal),
       do: {voucher_type(type), -withdrawal}

  defp typed_voucher_amount(type, _withdrawal, deposit)
       when type in ~w(receipt contra_deposit),
       do: {voucher_type(type), deposit}

  defp voucher_type(type) when type in ~w(contra_withdrawal contra_deposit), do: "Contra"
  defp voucher_type("payment"), do: "Payment"
  defp voucher_type("receipt"), do: "Receipt"

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

  defp bank_entry(name, counter_ledger, amount, date, reference) do
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
      tag("PAYMENTFAVOURING", counter_ledger),
      tag("INSTRUMENTNUMBER", reference),
      tag("PAYMENTMODE", "Transacted"),
      tag("BANKPARTYNAME", counter_ledger),
      tag("AMOUNT", money(amount)),
      "</BANKALLOCATIONS.LIST>",
      "</ALLLEDGERENTRIES.LIST>"
    ]
  end

  defp connector_envelope(messages, company) do
    IO.iodata_to_binary([
      "<ENVELOPE><HEADER><VERSION>1</VERSION><TALLYREQUEST>Import</TALLYREQUEST>",
      "<TYPE>Data</TYPE><ID>Vouchers</ID></HEADER><BODY><DESC><STATICVARIABLES>",
      tag("SVCURRENTCOMPANY", company),
      "<SVOVERWRITEIMPVCH>Yes</SVOVERWRITEIMPVCH>",
      "</STATICVARIABLES></DESC><DATA>",
      messages,
      "</DATA></BODY></ENVELOPE>"
    ])
  end

  defp company_name(statement) do
    case field(statement, :tally_company) do
      company when is_map(company) -> company |> field(:name) |> clean()
      _ -> nil
    end
  end

  defp remote_alt_guid(statement, transaction) do
    identity =
      Enum.join(
        [
          "nila-bank",
          field(statement, :id) || field(statement, :source_key),
          field(transaction, :identity) || value(transaction, "id") ||
            field(transaction, :ordinal)
        ],
        "|"
      )

    digest = Base.encode16(:crypto.hash(:sha256, identity), case: :lower)

    <<a::binary-size(8), b::binary-size(4), _::binary-size(1), c::binary-size(3),
      _::binary-size(1), d::binary-size(3), e::binary-size(12), _::binary>> = digest

    "#{a}-#{b}-8#{c}-8#{d}-#{e}"
  end

  defp field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp integer_field(value, key) do
    case field(value, key) do
      amount when is_integer(amount) -> amount
      _ -> 0
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
