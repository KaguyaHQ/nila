defmodule Nila.Gst.InvoiceFacts do
  @moduledoc """
  Canonical facts printed on an invoice-shaped GST document.

  This is the typed boundary between untrusted/provider-shaped maps and GST
  domain logic. It deliberately does not model whether the document is a sale
  or a purchase: `Sales.Invoice` and `Purchase.Bill` own those meanings.
  Monetary values are always integer paise and dates are always `Date` values.
  """

  alias Nila.Gst.{InvoiceLine, InvoiceParty, Money}

  @behaviour Access

  @enforce_keys [:document_type, :issuer, :recipient, :lines, :tax_paise, :origin]
  defstruct [
    :id,
    :document_type,
    :number,
    :date,
    :unreadable_date,
    :issuer,
    :recipient,
    :place_of_supply,
    :lines,
    :taxable_paise,
    :tax_paise,
    :total_paise,
    :printed_taxable_paise,
    :printed_tax_paise,
    :printed_total_paise,
    :source_pages,
    :source_attribution,
    :confidence,
    :verification,
    :origin,
    :evidence
  ]

  @type origin :: :sales | :purchase
  @type t :: %__MODULE__{
          id: String.t() | nil,
          document_type: String.t(),
          number: String.t() | nil,
          date: Date.t() | nil,
          unreadable_date: String.t() | nil,
          issuer: InvoiceParty.t() | nil,
          recipient: InvoiceParty.t() | nil,
          place_of_supply: String.t() | nil,
          lines: [InvoiceLine.t()],
          taxable_paise: integer() | nil,
          tax_paise: %{cgst: integer() | nil, sgst: integer() | nil, igst: integer() | nil},
          total_paise: integer() | nil,
          printed_taxable_paise: integer() | nil,
          printed_tax_paise: integer() | nil,
          printed_total_paise: integer() | nil,
          source_pages: [integer()],
          source_attribution: map() | nil,
          confidence: map(),
          verification: map(),
          origin: origin(),
          evidence: map()
        }

  @doc "Builds facts from the normalized sales projection, converting rupees once."
  def from_sales_map(%{"taxable_paise" => _value}),
    do: {:error, :purchase_projection_passed_as_sales_invoice}

  def from_sales_map(invoice) when is_map(invoice) do
    with {:ok, date, unreadable_date} <- read_date(invoice["invoice_date"]),
         {:ok, issuer} <- sales_party(invoice, "seller", "supplier"),
         {:ok, recipient} <- sales_party(invoice, "buyer", "bill_to"),
         {:ok, lines} <- lines(invoice["line_items"], &InvoiceLine.from_sales/1),
         {:ok, printed_taxable} <- rupee_money(invoice["printed_total_taxable"]),
         {:ok, printed_tax} <- rupee_money(invoice["printed_total_tax"]),
         {:ok, printed_total} <- rupee_money(invoice["printed_grand_total"]) do
      line_totals = line_totals(lines)

      {:ok,
       %__MODULE__{
         id: text(invoice["id"]),
         document_type: invoice["document_type"] || "invoice",
         number: text(invoice["invoice_number"]),
         date: date,
         unreadable_date: unreadable_date || text(invoice["unreadable_invoice_date"]),
         issuer: issuer,
         recipient: recipient,
         place_of_supply: text(invoice["place_of_supply"]),
         lines: lines,
         taxable_paise: line_totals.taxable,
         tax_paise: line_totals.tax,
         total_paise: add(line_totals.taxable, tax_total(line_totals.tax)),
         printed_taxable_paise: printed_taxable,
         printed_tax_paise: printed_tax,
         printed_total_paise: printed_total,
         source_pages: List.wrap(invoice["source_pages"] || invoice["pages"]),
         source_attribution: invoice["source_attribution"],
         confidence: invoice["confidence"] || %{},
         verification: invoice["verification"] || %{},
         origin: :sales,
         evidence: sales_evidence(invoice)
       }}
    end
  end

  def from_sales_map(_invoice), do: {:error, :invoice_must_be_a_map}

  @doc "Builds facts from the normalized purchase projection already in paise."
  def from_purchase_map(invoice)
      when is_map(invoice) and
             (not is_map_key(invoice, "taxable_paise") or
                not is_map_key(invoice, "tax_paise") or
                not is_map_key(invoice, "total_paise")),
      do: {:error, :purchase_money_projection_is_incomplete}

  def from_purchase_map(invoice) when is_map(invoice) do
    with {:ok, date, unreadable_date} <- read_date(invoice["invoice_date"]),
         {:ok, issuer} <- purchase_issuer(invoice),
         {:ok, lines} <- lines(invoice["line_items"], &InvoiceLine.from_purchase/1),
         {:ok, taxable} <- paise_money(invoice["taxable_paise"]),
         {:ok, tax} <- purchase_tax(invoice["tax_paise"]),
         {:ok, total} <- paise_money(invoice["total_paise"]),
         {:ok, printed_taxable} <- paise_money(invoice["printed_taxable_paise"]),
         {:ok, printed_total} <- paise_money(invoice["printed_total_paise"]) do
      {:ok,
       %__MODULE__{
         id: text(invoice["id"]),
         document_type: invoice["document_type"] || "invoice",
         number: text(invoice["invoice_number"]),
         date: date,
         unreadable_date: unreadable_date || text(invoice["unreadable_invoice_date"]),
         issuer: issuer,
         recipient: nil,
         place_of_supply: nil,
         lines: lines,
         taxable_paise: taxable,
         tax_paise: tax,
         total_paise: total,
         printed_taxable_paise: printed_taxable,
         printed_tax_paise: nil,
         printed_total_paise: printed_total,
         source_pages: List.wrap(invoice["source_pages"] || invoice["pages"]),
         source_attribution: invoice["source_attribution"],
         confidence: invoice["confidence"] || %{},
         verification: invoice["verification"] || %{},
         origin: :purchase,
         evidence: purchase_evidence(invoice)
       }}
    end
  end

  def from_purchase_map(_invoice), do: {:error, :invoice_must_be_a_map}

  @doc "Raises when a normalized sales projection violates the canonical contract."
  def from_sales_map!(invoice), do: unwrap!(from_sales_map(invoice), :sales)

  @doc "Raises when a normalized purchase projection violates the canonical contract."
  def from_purchase_map!(invoice), do: unwrap!(from_purchase_map(invoice), :purchase)

  @doc "Returns canonical sales facts, accepting either facts or a boundary projection."
  def sales!(%__MODULE__{origin: :sales} = facts), do: facts
  def sales!(invoice), do: from_sales_map!(invoice)

  @doc "Returns canonical purchase facts, accepting either facts or a boundary projection."
  def purchase!(%__MODULE__{origin: :purchase} = facts), do: facts
  def purchase!(invoice), do: from_purchase_map!(invoice)

  @doc "Checks a sales boundary and returns the original projection unchanged."
  def assert_sales!(%__MODULE__{origin: :sales} = facts), do: facts

  def assert_sales!(invoice) do
    _facts = from_sales_map!(invoice)
    invoice
  end

  @doc "Checks a purchase boundary and returns the original projection unchanged."
  def assert_purchase!(%__MODULE__{origin: :purchase} = facts), do: facts

  def assert_purchase!(invoice) do
    _facts = from_purchase_map!(invoice)
    invoice
  end

  @doc false
  def put_evidence(%__MODULE__{} = facts, key, value) do
    %{facts | evidence: Map.put(facts.evidence, key, value)}
  end

  @impl Access
  def fetch(%__MODULE__{} = facts, key) do
    case key do
      "id" -> {:ok, facts.id}
      "document_type" -> {:ok, facts.document_type}
      "invoice_number" -> {:ok, facts.number}
      "invoice_date" -> {:ok, facts.date || facts.unreadable_date}
      "unreadable_invoice_date" -> {:ok, facts.unreadable_date}
      "seller_name" -> {:ok, party_value(facts.issuer, :name)}
      "seller_gstin" -> {:ok, party_value(facts.issuer, :gstin)}
      "buyer_name" -> {:ok, party_value(facts.recipient, :name)}
      "buyer_gstin" -> {:ok, party_value(facts.recipient, :gstin)}
      "vendor_name" -> {:ok, party_value(facts.issuer, :name)}
      "vendor_gstin" -> {:ok, party_value(facts.issuer, :gstin)}
      "vendor_address" -> {:ok, party_value(facts.issuer, :address)}
      "supplier" -> {:ok, InvoiceParty.to_map(facts.issuer)}
      "bill_to" -> {:ok, InvoiceParty.to_map(facts.recipient)}
      "place_of_supply" -> {:ok, facts.place_of_supply}
      "line_items" -> {:ok, facts.lines}
      "taxable_paise" -> {:ok, facts.taxable_paise}
      "tax_paise" -> {:ok, tax_map(facts.tax_paise)}
      "total_paise" -> {:ok, facts.total_paise}
      "printed_total_taxable" -> {:ok, rupees(facts.printed_taxable_paise)}
      "printed_total_tax" -> {:ok, rupees(facts.printed_tax_paise)}
      "printed_grand_total" -> {:ok, rupees(facts.printed_total_paise)}
      "printed_taxable_paise" -> {:ok, facts.printed_taxable_paise}
      "printed_total_paise" -> {:ok, facts.printed_total_paise}
      "source_pages" -> {:ok, facts.source_pages}
      "pages" -> {:ok, facts.source_pages}
      "source_attribution" -> {:ok, facts.source_attribution}
      "confidence" -> {:ok, facts.confidence}
      "verification" -> {:ok, facts.verification}
      other -> Map.fetch(facts.evidence, other)
    end
  end

  @impl Access
  def get_and_update(_facts, _key, _function),
    do: raise(ArgumentError, "InvoiceFacts are immutable; project them before editing")

  @impl Access
  def pop(_facts, _key),
    do: raise(ArgumentError, "InvoiceFacts are immutable; project them before editing")

  @doc "Explicit persistence/integration projection for an existing sales invoice."
  def to_sales_map(%__MODULE__{origin: :sales} = facts) do
    facts.evidence
    |> Map.merge(%{
      "document_type" => facts.document_type,
      "invoice_number" => facts.number,
      "invoice_date" => facts.date || facts.unreadable_date,
      "seller_name" => party_value(facts.issuer, :name),
      "seller_gstin" => party_value(facts.issuer, :gstin),
      "buyer_name" => party_value(facts.recipient, :name),
      "buyer_gstin" => party_value(facts.recipient, :gstin),
      "supplier" => InvoiceParty.to_map(facts.issuer),
      "bill_to" => InvoiceParty.to_map(facts.recipient),
      "place_of_supply" => facts.place_of_supply,
      "line_items" => Enum.map(facts.lines, &InvoiceLine.to_sales_map/1),
      "printed_total_taxable" => rupees(facts.printed_taxable_paise),
      "printed_total_tax" => rupees(facts.printed_tax_paise),
      "printed_grand_total" => rupees(facts.printed_total_paise),
      "source_pages" => facts.source_pages,
      "source_attribution" => facts.source_attribution,
      "confidence" => facts.confidence,
      "verification" => facts.verification
    })
    |> maybe_put("id", facts.id)
  end

  @doc "Explicit persistence/integration projection for an existing purchase bill."
  def to_purchase_map(%__MODULE__{origin: :purchase} = facts) do
    Map.merge(facts.evidence, %{
      "id" => facts.id,
      "document_type" => facts.document_type,
      "invoice_number" => facts.number,
      "invoice_date" => facts.date,
      "unreadable_invoice_date" => facts.unreadable_date,
      "vendor_name" => party_value(facts.issuer, :name),
      "vendor_gstin" => party_value(facts.issuer, :gstin),
      "vendor_address" => party_value(facts.issuer, :address),
      "line_items" => Enum.map(facts.lines, &InvoiceLine.to_purchase_map/1),
      "taxable_paise" => facts.taxable_paise,
      "tax_paise" => %{
        "cgst" => facts.tax_paise.cgst,
        "sgst" => facts.tax_paise.sgst,
        "igst" => facts.tax_paise.igst
      },
      "total_paise" => facts.total_paise,
      "printed_taxable_paise" => facts.printed_taxable_paise,
      "printed_total_paise" => facts.printed_total_paise,
      "pages" => facts.source_pages,
      "source_attribution" => facts.source_attribution,
      "confidence" => facts.confidence
    })
  end

  defp sales_party(invoice, prefix, nested) do
    base = invoice[nested] || %{}

    InvoiceParty.new(%{
      "name" => invoice["#{prefix}_name"] || base["name"],
      "gstin" => invoice["#{prefix}_gstin"] || base["gstin"],
      "address" => base["address"],
      "state_code" => base["state_code"]
    })
  end

  defp purchase_issuer(invoice) do
    InvoiceParty.new(%{
      "name" => invoice["vendor_name"],
      "gstin" => invoice["vendor_gstin"],
      "address" => invoice["vendor_address"]
    })
  end

  defp lines(nil, _builder), do: {:ok, []}

  defp lines(lines, builder) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, result} ->
      case builder.(line) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | result]}}
        {:error, reason} -> {:halt, {:error, {:line, index, reason}}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp lines(_lines, _builder), do: {:error, :line_items_must_be_a_list}

  defp read_date(nil), do: {:ok, nil, nil}
  defp read_date(%Date{} = date), do: {:ok, date, nil}

  defp read_date(value) when is_binary(value) do
    case value |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> {:ok, date, nil}
      {:error, _reason} -> {:ok, nil, text(value)}
    end
  end

  defp read_date(value), do: {:ok, nil, inspect(value)}

  defp rupee_money(nil), do: {:ok, nil}

  defp rupee_money(value) do
    case Money.paise_or_error(value) do
      {:ok, paise} -> {:ok, paise}
      :missing -> {:ok, nil}
      :unreadable -> {:error, :unreadable_money}
    end
  end

  defp paise_money(nil), do: {:ok, nil}
  defp paise_money(value) when is_integer(value), do: {:ok, value}
  defp paise_money(_value), do: {:error, :must_be_integer_paise}

  defp purchase_tax(nil), do: {:ok, %{cgst: 0, sgst: 0, igst: 0}}

  defp purchase_tax(tax) when is_map(tax) do
    with {:ok, cgst} <- optional_paise(tax["cgst"]),
         {:ok, sgst} <- optional_paise(tax["sgst"]),
         {:ok, igst} <- optional_paise(tax["igst"]) do
      {:ok, %{cgst: cgst, sgst: sgst, igst: igst}}
    end
  end

  defp purchase_tax(_tax), do: {:error, :tax_paise_must_be_a_map}

  defp optional_paise(nil), do: {:ok, 0}
  defp optional_paise(value), do: paise_money(value)

  defp line_totals(lines) do
    taxable = sum_required(lines, & &1.taxable_paise)

    tax = %{
      cgst: sum_optional(lines, & &1.tax_paise.cgst),
      sgst: sum_optional(lines, & &1.tax_paise.sgst),
      igst: sum_optional(lines, & &1.tax_paise.igst)
    }

    %{taxable: taxable, tax: tax}
  end

  defp sum_required(lines, field) do
    if Enum.all?(lines, &is_integer(field.(&1))) do
      Enum.sum(Enum.map(lines, field))
    end
  end

  defp sum_optional(lines, field), do: lines |> Enum.map(&(field.(&1) || 0)) |> Enum.sum()
  defp tax_total(tax), do: tax.cgst + tax.sgst + tax.igst
  defp add(nil, _right), do: nil
  defp add(left, right), do: left + right

  defp sales_evidence(invoice) do
    Map.drop(invoice, ~w(
      id document_type invoice_number invoice_date unreadable_invoice_date
      seller_name seller_gstin buyer_name buyer_gstin supplier bill_to
      place_of_supply line_items printed_total_taxable printed_total_tax
      printed_grand_total source_pages pages source_attribution confidence verification
    ))
  end

  defp purchase_evidence(invoice) do
    Map.drop(invoice, ~w(
      id document_type invoice_number invoice_date unreadable_invoice_date
      vendor_name vendor_gstin vendor_address line_items taxable_paise tax_paise
      total_paise printed_taxable_paise printed_total_paise source_pages pages
      source_attribution confidence verification
    ))
  end

  defp party_value(nil, _field), do: nil
  defp party_value(party, field), do: Map.fetch!(party, field)

  defp tax_map(tax), do: %{"cgst" => tax.cgst, "sgst" => tax.sgst, "igst" => tax.igst}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp rupees(nil), do: nil

  defp rupees(paise) when rem(paise, 100) == 0, do: div(paise, 100)
  defp rupees(paise), do: paise |> Money.rupees() |> Decimal.to_float()

  defp text(nil), do: nil
  defp text(value), do: value |> to_string() |> String.trim() |> blank_to_nil()
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp unwrap!({:ok, facts}, _origin), do: facts

  defp unwrap!({:error, reason}, origin) do
    raise ArgumentError, "invalid normalized #{origin} invoice: #{inspect(reason)}"
  end
end
