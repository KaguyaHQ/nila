defmodule Nila.Gst.Filing.TallyPrime do
  @moduledoc """
  Imports Nila's effective sales invoices into the TallyPrime company currently
  open on the local machine.

  This first adapter writes accounting vouchers against existing ledgers. It
  does not create party, sales, or GST ledger masters in TallyPrime.
  """

  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Gstr1

  @endpoint "http://localhost:9000/"
  @available Mix.env() != :prod
  @invalid_xml ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u
  @voucher_types %{
    "invoice" => "Sales",
    "credit_note" => "Credit Note",
    "debit_note" => "Debit Note"
  }

  @type import_result :: %{
          required(:created) => non_neg_integer(),
          required(:altered) => non_neg_integer(),
          required(:combined) => non_neg_integer(),
          required(:ignored) => non_neg_integer(),
          required(:errors) => non_neg_integer(),
          required(:exceptions) => non_neg_integer(),
          required(:line_errors) => [String.t()]
        }

  @doc "Whether direct local TallyPrime writes are available in this deployment."
  def available?, do: @available

  @doc "Builds an accounting-voucher import envelope for all effective active sales documents."
  @spec build(map()) :: {:ok, binary()} | {:error, :no_active_sales | :invalid_sales_data}
  def build(projection) when is_map(projection) do
    build_envelope(projection, nil)
  end

  def build(_projection), do: {:error, :invalid_sales_data}

  @doc "Builds a company-scoped voucher envelope and returns its expected import count."
  def build_for_company(projection, company)
      when is_map(projection) and is_binary(company) and byte_size(company) <= 200 do
    company = String.trim(company)

    if company == "" do
      {:error, :invalid_company}
    else
      case build_envelope(projection, company) do
        {:ok, xml} -> {:ok, xml, length(effective_active_invoices(projection))}
        error -> error
      end
    end
  end

  def build_for_company(_projection, _company), do: {:error, :invalid_company}

  @doc "Builds one company-scoped import envelope per logical voucher."
  def build_items_for_company(projection, company)
      when is_map(projection) and is_binary(company) and byte_size(company) <= 200 do
    company = String.trim(company)
    active = effective_active_invoices(projection)
    period = projection[:period] || projection["period"]

    with true <- company != "",
         :ok <- require_invoices(active) do
      active
      |> Enum.reduce_while({:ok, []}, fn invoice, {:ok, items} ->
        case voucher(invoice, period) do
          {:ok, voucher_xml} ->
            xml = IO.iodata_to_binary(voucher_xml)

            item = %{
              source_id: remote_id(invoice, period),
              invoice_number: invoice["invoice_number"],
              ledger_names: voucher_ledger_names(xml),
              xml: envelope(xml, company)
            }

            {:cont, {:ok, [item | items]}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    else
      false -> {:error, :invalid_company}
      error -> error
    end
  end

  def build_items_for_company(_projection, _company), do: {:error, :invalid_company}

  defp build_envelope(projection, company) do
    active = effective_active_invoices(projection)

    with :ok <- require_invoices(active),
         {:ok, vouchers} <- build_vouchers(active, projection[:period] || projection["period"]) do
      {:ok, envelope(vouchers, company)}
    end
  end

  @doc "Builds and posts the voucher envelope to the local TallyPrime HTTP server."
  @spec push(map(), keyword()) :: {:ok, import_result()} | {:error, term()}
  def push(projection, opts \\ []) do
    request = Keyword.get(opts, :request, &post/1)
    active = effective_active_invoices(projection)

    with :ok <- require_invoices(active),
         {:ok, xml} <- build(Map.put(projection, :active_invoices, active)),
         {:ok, response} <- request.(xml),
         {:ok, body} <- response_body(response) do
      parse_response(body, length(active))
    end
  end

  @doc "Parses TallyPrime's voucher import result."
  @spec parse_response(binary(), non_neg_integer() | nil) ::
          {:ok, import_result()}
          | {:error,
             :invalid_response
             | {:partial_import, import_result()}
             | {:tally_rejected, import_result()}}
  def parse_response(body, expected \\ nil)

  def parse_response(body, expected) when is_binary(body) do
    result = %{
      created: integer_tag(body, "CREATED"),
      altered: integer_tag(body, "ALTERED"),
      combined: integer_tag(body, "COMBINED"),
      ignored: integer_tag(body, "IGNORED"),
      errors: integer_tag(body, "ERRORS"),
      exceptions: integer_tag(body, "EXCEPTIONS"),
      line_errors: line_errors(body)
    }

    accounted = result.created + result.altered + result.combined + result.ignored
    import_result? = Regex.match?(~r/<IMPORTRESULT>/i, body)
    direct_response? = Regex.match?(~r/^\s*<RESPONSE>/i, body)
    counts? = Enum.any?(~w(CREATED ALTERED COMBINED IGNORED ERRORS EXCEPTIONS), &tag?(body, &1))
    status_present? = tag?(body, "STATUS")

    successful_envelope? =
      integer_tag(body, "STATUS") == 1 or (direct_response? and not status_present?)

    cond do
      not (import_result? or direct_response?) or not counts? ->
        {:error, :invalid_response}

      not successful_envelope? or result.errors > 0 or result.exceptions > 0 or
          result.line_errors != [] ->
        {:error, {:tally_rejected, result}}

      is_integer(expected) and accounted != expected ->
        {:error, {:partial_import, result}}

      true ->
        {:ok, result}
    end
  end

  def parse_response(_body, _expected), do: {:error, :invalid_response}

  defp build_vouchers(invoices, period) do
    invoices
    |> Enum.reduce_while({:ok, []}, fn invoice, {:ok, vouchers} ->
      case voucher(invoice, period) do
        {:ok, voucher} -> {:cont, {:ok, [voucher | vouchers]}}
        {:error, :invalid_sales_data} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, vouchers} -> {:ok, vouchers |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp voucher(invoice, period) do
    document_type = Gstr1.document_type(invoice)
    voucher_type = @voucher_types[document_type]
    effect = Gstr1.document_effect(invoice)
    lines = List.wrap(invoice["line_items"])

    with %Date{} = date <- invoice_date(invoice["invoice_date"]),
         true <- present?(invoice["invoice_number"]),
         true <- present?(voucher_type),
         {:ok, party} <- party_ledger(invoice),
         {:ok, amounts} <- amounts(lines),
         :ok <- valid_text_fields([invoice["seller_gstin"], invoice["invoice_number"], party]) do
      postings =
        [
          {"Sales", effect * amounts.taxable},
          {"Output CGST", effect * amounts.cgst},
          {"Output SGST", effect * amounts.sgst},
          {"Output IGST", effect * amounts.igst}
        ]
        |> Enum.reject(fn {_name, paise} -> paise == 0 end)

      party_amount = -Enum.sum(Enum.map(postings, &elem(&1, 1)))
      entries = [ledger_entry(party, party_amount) | Enum.map(postings, &ledger_entry/1)]

      {:ok,
       [
         "<TALLYMESSAGE>",
         "<VOUCHER REMOTEID=\"",
         remote_id(invoice, period),
         "\" VCHTYPE=\"",
         xml(voucher_type),
         "\" ACTION=\"Create\" VIEW=\"Accounting Voucher View\">",
         tag("DATE", Calendar.strftime(date, "%Y%m%d")),
         tag("EFFECTIVEDATE", Calendar.strftime(date, "%Y%m%d")),
         tag("VOUCHERTYPENAME", voucher_type),
         tag("VOUCHERNUMBER", invoice["invoice_number"]),
         tag("PARTYLEDGERNAME", party),
         tag("PERSISTEDVIEW", "Accounting Voucher View"),
         tag("ISINVOICE", "No"),
         tag("NARRATION", "Imported from Nila"),
         entries,
         "</VOUCHER>",
         "</TALLYMESSAGE>"
       ]}
    else
      _invalid -> {:error, :invalid_sales_data}
    end
  end

  defp party_ledger(invoice) do
    case Gstr1.recipient_registration(invoice) do
      "registered" ->
        if present?(invoice["buyer_name"]),
          do: {:ok, String.trim(invoice["buyer_name"])},
          else: {:error, :invalid_sales_data}

      "unregistered" ->
        {:ok, "Cash"}

      _unknown ->
        {:error, :invalid_sales_data}
    end
  end

  defp amounts([]), do: {:error, :invalid_sales_data}

  defp amounts(lines) do
    Enum.reduce_while(
      lines,
      {:ok, %{taxable: 0, cgst: 0, sgst: 0, igst: 0}},
      fn line, {:ok, totals} ->
        with {:ok, taxable} <- required_paise(line["taxable_value"]),
             {:ok, cgst} <- optional_paise(line["cgst_amount"]),
             {:ok, sgst} <- optional_paise(line["sgst_amount"]),
             {:ok, igst} <- optional_paise(line["igst_amount"]) do
          {:cont,
           {:ok,
            %{
              taxable: totals.taxable + taxable,
              cgst: totals.cgst + cgst,
              sgst: totals.sgst + sgst,
              igst: totals.igst + igst
            }}}
        else
          _invalid -> {:halt, {:error, :invalid_sales_data}}
        end
      end
    )
  end

  defp required_paise(value) do
    case Books.paise_or_error(value) do
      {:ok, paise} when paise >= 0 -> {:ok, paise}
      _missing_or_invalid -> {:error, :invalid_sales_data}
    end
  end

  defp optional_paise(nil), do: {:ok, 0}
  defp optional_paise(value), do: required_paise(value)

  defp ledger_entry({name, amount}), do: ledger_entry(name, amount)

  defp ledger_entry(name, amount) do
    [
      "<ALLLEDGERENTRIES.LIST>",
      tag("LEDGERNAME", name),
      tag("ISDEEMEDPOSITIVE", if(amount < 0, do: "Yes", else: "No")),
      tag("AMOUNT", money(amount)),
      "</ALLLEDGERENTRIES.LIST>"
    ]
  end

  defp envelope(vouchers, company) do
    company_variable = if company, do: tag("SVCURRENTCOMPANY", company), else: ""

    IO.iodata_to_binary([
      "<ENVELOPE>",
      "<HEADER><VERSION>1</VERSION><TALLYREQUEST>Import</TALLYREQUEST><TYPE>Data</TYPE><ID>Vouchers</ID></HEADER>",
      "<BODY><DESC><STATICVARIABLES><IMPORTDUPS>@@DUPIGNORE</IMPORTDUPS>",
      company_variable,
      "</STATICVARIABLES></DESC>",
      "<DATA>",
      vouchers,
      "</DATA></BODY></ENVELOPE>"
    ])
  end

  defp remote_id(invoice, period) do
    source_identity =
      invoice["id"] ||
        Enum.join(
          [Gstr1.document_type(invoice), invoice["invoice_date"], invoice["invoice_number"]],
          "|"
        )

    identity =
      Enum.join(
        ["nila", invoice["seller_gstin"], period || invoice["invoice_date"], source_identity],
        "|"
      )

    "nila-" <> Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end

  defp voucher_ledger_names(xml) do
    ~r/<LEDGERNAME>(.*?)<\/LEDGERNAME>/is
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map(fn [name] -> name |> unescape() |> String.trim() end)
    |> Enum.uniq()
  end

  defp post(xml) do
    Req.post(
      url: @endpoint,
      body: xml,
      headers: [{"content-type", "text/xml"}],
      retry: false,
      receive_timeout: 15_000
    )
  end

  defp response_body(%{status: status, body: body}) when status in 200..299 and is_binary(body),
    do: {:ok, body}

  defp response_body(%{status: status}) when is_integer(status),
    do: {:error, {:http_status, status}}

  defp response_body(_response), do: {:error, :invalid_response}

  defp invoice_date(%Date{} = date), do: date
  defp invoice_date(value) when is_binary(value), do: Books.parse_date(value)
  defp invoice_date(_value), do: nil

  defp effective_active_invoices(%{active_invoices: invoices}) when is_list(invoices),
    do: Enum.filter(invoices, &active_document?/1)

  defp effective_active_invoices(%{invoices: invoices}) when is_list(invoices) do
    Enum.filter(invoices, &(active_document?(&1) and is_nil(&1["duplicate_copy"])))
  end

  defp effective_active_invoices(_projection), do: :invalid

  defp active_document?(invoice), do: invoice["document_status"] in [nil, "active"]

  defp require_invoices(:invalid), do: {:error, :invalid_sales_data}
  defp require_invoices([]), do: {:error, :no_active_sales}
  defp require_invoices(_invoices), do: :ok

  defp valid_text_fields(values) do
    if Enum.all?(values, &(present?(&1) and not Regex.match?(@invalid_xml, &1))),
      do: :ok,
      else: {:error, :invalid_sales_data}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp money(paise) do
    sign = if paise < 0, do: "-", else: ""
    absolute = abs(paise)
    rupees = Integer.to_string(div(absolute, 100))
    paise = absolute |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> rupees <> "." <> paise
  end

  defp tag(name, value), do: ["<", name, ">", xml(to_string(value)), "</", name, ">"]

  defp xml(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp tag?(body, tag), do: Regex.match?(Regex.compile!("<#{tag}>", "i"), body)

  defp integer_tag(body, tag) do
    case Regex.run(Regex.compile!("<#{tag}>\\s*(\\d+)\\s*</#{tag}>", "i"), body) do
      [_, value] -> String.to_integer(value)
      _missing -> 0
    end
  end

  defp line_errors(body) do
    ~r/<LINEERROR>(.*?)<\/LINEERROR>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [message] -> message |> unescape() |> String.trim() end)
  end

  defp unescape(value) do
    value
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end
end
