defmodule Nila.Gst.Filing.TallyPrime do
  @moduledoc """
  Imports Nila's effective sales invoices into the TallyPrime company currently
  open on the local machine.

  The connector may create a missing registered-party ledger. Sales and GST
  control ledgers must already exist in TallyPrime.
  """

  alias Nila.Gst.Money
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.StateCodes

  @endpoint "http://localhost:9000/"
  @available Mix.env() != :prod
  @invalid_xml ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u
  @voucher_types %{
    "invoice" => "Sales",
    "credit_note" => "Credit Note",
    "debit_note" => "Debit Note"
  }
  @default_posting_ledgers %{
    "sales_ledger" => "Sales",
    "cgst_ledger" => "Output CGST",
    "sgst_ledger" => "Output SGST",
    "igst_ledger" => "Output IGST"
  }
  @posting_key_atoms %{
    "party_ledger" => :party_ledger,
    "sales_ledger" => :sales_ledger,
    "line_sales_ledgers" => :line_sales_ledgers,
    "cgst_ledger" => :cgst_ledger,
    "sgst_ledger" => :sgst_ledger,
    "igst_ledger" => :igst_ledger
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

  @doc "Requires the selected Tally company to carry the same GSTIN as the Nila client."
  def validate_company_gstin(%{gstin: nil}, client_gstin) when is_binary(client_gstin),
    do: {:error, :tally_company_gstin_missing}

  def validate_company_gstin(%{gstin: tally_gstin}, client_gstin)
      when is_binary(tally_gstin) and is_binary(client_gstin) do
    if normalize_gstin(tally_gstin) == normalize_gstin(client_gstin) do
      :ok
    else
      {:error, {:tally_company_gstin_mismatch, tally_gstin, client_gstin}}
    end
  end

  def validate_company_gstin(_company, _client_gstin),
    do: {:error, :tally_company_gstin_missing}

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
              source_id: source_id(invoice, period),
              invoice_number: invoice["invoice_number"],
              voucher_type: voucher_type(invoice),
              ledger_names: voucher_ledger_names(xml),
              party_ledger: party_ledger_master(invoice),
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

  defp voucher(invoice, _period) do
    voucher_type = voucher_type(invoice)
    effect = Gstr1.document_effect(invoice)
    lines = List.wrap(invoice["line_items"])
    correlation_id = Ecto.UUID.generate()

    with %Date{} = date <- invoice_date(invoice["invoice_date"]),
         true <- present?(invoice["invoice_number"]),
         true <- present?(voucher_type),
         {:ok, party} <- party_ledger(invoice),
         {:ok, party_details} <- party_details(invoice),
         {:ok, amounts} <- amounts(lines),
         {:ok, sales_ledger} <- posting_ledger(invoice, "sales_ledger"),
         {:ok, sales_entries} <- sales_entries(invoice, lines, effect, sales_ledger),
         {:ok, postings} <- tax_postings(invoice, effect, amounts),
         {:ok, party_amount} <- balanced_party_amount(sales_entries, postings),
         narration = blank_to_nil(invoice["narration"]) || "Imported from Nila",
         :ok <-
           valid_text_fields(
             [
               invoice["seller_gstin"],
               invoice["invoice_number"],
               party,
               sales_ledger,
               narration
             ] ++
               Enum.map(sales_entries, & &1.ledger_name) ++
               Enum.map(postings, &elem(&1, 0))
           ) do
      entries =
        [party_ledger_entry(party, party_amount, invoice["invoice_number"])] ++
          Enum.map(sales_entries, &gst_sales_entry/1) ++ Enum.map(postings, &ledger_entry/1)

      {:ok,
       [
         "<TALLYMESSAGE>",
         "<VOUCHER REMOTEID=\"",
         correlation_id,
         "\" VCHTYPE=\"",
         xml(voucher_type),
         "\" ACTION=\"Create\" OBJVIEW=\"Invoice Voucher View\">",
         tag("DATE", Calendar.strftime(date, "%Y%m%d")),
         tag("EFFECTIVEDATE", Calendar.strftime(date, "%Y%m%d")),
         tag("GUID", correlation_id),
         tag("VOUCHERTYPENAME", voucher_type),
         tag("VOUCHERNUMBER", invoice["invoice_number"]),
         tag("PARTYLEDGERNAME", party),
         tag("PARTYNAME", party),
         tag("PARTYMAILINGNAME", invoice["buyer_name"] || party),
         tag("BASICBUYERNAME", invoice["buyer_name"] || party),
         tag("GSTREGISTRATIONTYPE", party_details.registration_type),
         optional_tag("PARTYGSTIN", party_details.gstin),
         optional_tag("STATENAME", party_details.state),
         tag("COUNTRYOFRESIDENCE", "India"),
         tag("PERSISTEDVIEW", "Invoice Voucher View"),
         tag("ISINVOICE", "Yes"),
         tag("ISGSTOVERRIDDEN", "Yes"),
         tag("NARRATION", narration),
         entries,
         "</VOUCHER>",
         "</TALLYMESSAGE>"
       ]}
    else
      _invalid -> {:error, :invalid_sales_data}
    end
  end

  defp voucher_type(invoice), do: @voucher_types[Gstr1.document_type(invoice)]

  defp party_ledger(invoice) do
    with {:ok, default} <- default_party_ledger(invoice) do
      posting_ledger(invoice, "party_ledger", default)
    end
  end

  defp default_party_ledger(invoice) do
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

  defp posting_ledger(invoice, key, default \\ nil) do
    posting = invoice["tally_posting"] || invoice[:tally_posting]
    default = default || @default_posting_ledgers[key]
    atom_key = @posting_key_atoms[key]

    value =
      case posting do
        map when is_map(map) -> Map.get(map, key, Map.get(map, atom_key, default))
        _missing -> default
      end

    if present?(value),
      do: {:ok, String.trim(value)},
      else: {:error, :invalid_sales_data}
  end

  defp tax_postings(invoice, effect, amounts) do
    [
      {"cgst_ledger", amounts.cgst},
      {"sgst_ledger", amounts.sgst},
      {"igst_ledger", amounts.igst}
    ]
    |> Enum.reject(fn {_key, paise} -> paise == 0 end)
    |> Enum.reduce_while({:ok, []}, fn {key, paise}, {:ok, postings} ->
      case posting_ledger(invoice, key) do
        {:ok, name} -> {:cont, {:ok, [{name, effect * paise} | postings]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, postings} -> {:ok, Enum.reverse(postings)}
      error -> error
    end
  end

  defp balanced_party_amount(sales_entries, postings) do
    posting_amounts =
      Enum.map(sales_entries, & &1.amount) ++ Enum.map(postings, &elem(&1, 1))

    party_amount = -Enum.sum(posting_amounts)

    if Enum.sum([party_amount | posting_amounts]) == 0,
      do: {:ok, party_amount},
      else: {:error, :invalid_sales_data}
  end

  defp line_sales_ledgers(invoice) do
    posting = invoice["tally_posting"] || invoice[:tally_posting]

    case posting do
      map when is_map(map) ->
        case Map.get(map, "line_sales_ledgers", Map.get(map, :line_sales_ledgers, %{})) do
          line_ledgers when is_map(line_ledgers) -> {:ok, line_ledgers}
          _invalid -> {:error, :invalid_sales_data}
        end

      _missing ->
        {:ok, %{}}
    end
  end

  defp line_sales_ledger(line_ledgers, line, index, fallback) do
    keys =
      [line["id"], line["source_id"], Integer.to_string(index), index]
      |> Enum.reject(&is_nil/1)

    selected = Enum.find_value(keys, fallback, &Map.get(line_ledgers, &1))

    if present?(selected),
      do: {:ok, String.trim(selected)},
      else: {:error, :invalid_sales_data}
  end

  defp party_details(invoice) do
    registration = Gstr1.recipient_registration(invoice)
    gstin = blank_to_nil(invoice["buyer_gstin"])

    party_state =
      if registration == "registered", do: StateCodes.name_for(to_string(gstin || ""))

    cond do
      registration == "registered" and is_nil(gstin) ->
        {:error, :invalid_sales_data}

      registration not in ["registered", "unregistered"] or
          (registration == "registered" and is_nil(party_state)) ->
        {:error, :invalid_sales_data}

      true ->
        {:ok,
         %{
           registration_type:
             if(registration == "registered", do: "Regular", else: "Unregistered"),
           gstin: gstin,
           state: party_state
         }}
    end
  end

  defp party_ledger_master(invoice) do
    with "registered" <- Gstr1.recipient_registration(invoice),
         {:ok, name} <- party_ledger(invoice),
         {:ok, details} <- party_details(invoice) do
      %{
        name: name,
        parent: "Sundry Debtors",
        gstin: details.gstin,
        registration_type: details.registration_type,
        state: details.state,
        country: "India",
        applicable_from: invoice["invoice_date"]
      }
    else
      _not_registered -> nil
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
    case Money.paise_or_error(value) do
      {:ok, paise} when paise >= 0 -> {:ok, paise}
      _missing_or_invalid -> {:error, :invalid_sales_data}
    end
  end

  defp optional_paise(nil), do: {:ok, 0}
  defp optional_paise(value), do: required_paise(value)

  defp sales_entries(invoice, lines, effect, fallback_ledger) do
    with {:ok, line_ledgers} <- line_sales_ledgers(invoice) do
      lines
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, entries} ->
        with {:ok, taxable} <- required_paise(line["taxable_value"]),
             {:ok, rate} <- gst_rate(line),
             {:ok, ledger_name} <-
               line_sales_ledger(line_ledgers, line, index, fallback_ledger),
             description when is_binary(description) and description != "" <-
               blank_to_nil(line["description"] || line["item_name"]) do
          hsn = blank_to_nil(line["hsn_sac"])

          entry = %{
            amount: effect * taxable,
            description: description,
            hsn: hsn,
            index: index,
            ledger_name: ledger_name,
            rate: rate,
            supply_type:
              if(is_binary(hsn),
                do: if(String.starts_with?(hsn, "99"), do: "Services", else: "Goods")
              )
          }

          {:cont, {:ok, [entry | entries]}}
        else
          _invalid -> {:halt, {:error, :invalid_sales_data}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  defp gst_rate(line) do
    candidates = [
      line["igst_rate"],
      double_rate(line["cgst_rate"]),
      double_rate(line["sgst_rate"]),
      line["gst_rate"],
      inferred_rate(line)
    ]

    case Enum.find(candidates, &(is_number(&1) and &1 >= 0 and &1 <= 100)) do
      rate when is_number(rate) -> {:ok, rate}
      _missing -> {:error, :invalid_sales_data}
    end
  end

  defp double_rate(value) when is_number(value), do: value * 2
  defp double_rate(_value), do: nil

  defp inferred_rate(%{"taxable_value" => taxable} = line)
       when is_number(taxable) and taxable > 0 do
    tax =
      Enum.reduce(~w(cgst_amount sgst_amount igst_amount), 0, fn key, total ->
        case line[key] do
          value when is_number(value) -> total + value
          _missing -> total
        end
      end)

    Float.round(tax * 100 / taxable, 4)
  end

  defp inferred_rate(_line), do: nil

  defp party_ledger_entry(name, amount, invoice_number) do
    [
      "<LEDGERENTRIES.LIST>",
      tag("LEDGERNAME", name),
      tag("ISDEEMEDPOSITIVE", if(amount < 0, do: "Yes", else: "No")),
      tag("ISLASTDEEMEDPOSITIVE", "No"),
      tag("ISPARTYLEDGER", "Yes"),
      tag("AMOUNT", money(amount)),
      "<BILLALLOCATIONS.LIST>",
      tag("NAME", invoice_number),
      tag("BILLTYPE", "New Ref"),
      tag("AMOUNT", money(amount)),
      "</BILLALLOCATIONS.LIST>",
      "</LEDGERENTRIES.LIST>"
    ]
  end

  defp gst_sales_entry(entry) do
    half_rate = entry.rate / 2

    [
      "<LEDGERENTRIES.LIST>",
      tag("LEDGERNAME", entry.ledger_name),
      tag("ISDEEMEDPOSITIVE", if(entry.amount < 0, do: "Yes", else: "No")),
      tag("ISLASTDEEMEDPOSITIVE", "No"),
      tag("ISPARTYLEDGER", "No"),
      tag("GSTOVRDNTAXABILITY", "Taxable"),
      optional_tag("GSTOVRDNTYPEOFSUPPLY", entry.supply_type),
      hsn_tags(entry),
      tag("GSTRATEINFERAPPLICABILITY", "As per Masters/Company"),
      tag("ISGSTASSESSABLEVALUEOVERRIDDEN", "Yes"),
      tag("GSTOVRDNASSESSABLEVALUE", money(entry.amount)),
      rate_detail("CGST", half_rate),
      rate_detail("SGST/UTGST", half_rate),
      rate_detail("IGST", entry.rate),
      tag("AMOUNT", money(entry.amount)),
      "<BASICUSERDESCRIPTION.LIST>",
      tag("BASICUSERDESCRIPTION", entry.description),
      "</BASICUSERDESCRIPTION.LIST>",
      "</LEDGERENTRIES.LIST>"
    ]
  end

  defp hsn_tags(%{hsn: nil}), do: ""

  defp hsn_tags(entry) do
    [
      tag("GSTHSNNAME", entry.hsn),
      tag("GSTHSNDESCRIPTION", entry.description),
      tag("GSTHSNINFERAPPLICABILITY", "As per Masters/Company")
    ]
  end

  defp rate_detail(head, rate) do
    [
      "<RATEDETAILS.LIST>",
      tag("GSTRATEDUTYHEAD", head),
      tag("GSTRATEVALUATIONTYPE", "Based on Value"),
      tag("GSTRATE", decimal(rate)),
      "</RATEDETAILS.LIST>"
    ]
  end

  defp ledger_entry({name, amount}), do: ledger_entry(name, amount)

  defp ledger_entry(name, amount) do
    [
      "<LEDGERENTRIES.LIST>",
      tag("LEDGERNAME", name),
      tag("ISDEEMEDPOSITIVE", if(amount < 0, do: "Yes", else: "No")),
      tag("ISLASTDEEMEDPOSITIVE", "No"),
      tag("AMOUNT", money(amount)),
      "</LEDGERENTRIES.LIST>"
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

  defp source_id(invoice, period) do
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

    identity
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  defp decimal(value) when is_integer(value), do: Integer.to_string(value)

  defp decimal(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp normalize_gstin(value), do: value |> String.trim() |> String.upcase()

  defp optional_tag(_name, nil), do: ""
  defp optional_tag(name, value), do: tag(name, value)

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
