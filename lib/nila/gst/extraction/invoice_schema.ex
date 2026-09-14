defmodule Nila.Gst.Extraction.InvoiceSchema do
  @moduledoc """
  Field definitions and response shapes for one extracted GST invoice.

  The ordered line properties define both the named-object schema and the
  positional row schema, including decoding. Add or change a line field there.

  Keep semantic roles explicit here before compensating in prompts or adding
  confidence fields. Invoice-level tax totals remain distinct from summary rows,
  and sales parties remain split into Bill To and Ship To instead of asking the
  model to determine tax treatment from their addresses.
  """

  @doc "Base field definitions with named line-item objects."
  def object_schema(kind, contract \\ :current)
      when (kind in [:purchase, :sales] and contract == :current) or
             (kind == :sales and contract == :semantic) do
    kind
    |> invoice_properties()
    |> put_in([:line_items, :items], line_item_schema(contract))
    |> strict_object()
  end

  @doc "Ordered fields used to encode and decode positional invoice rows."
  def line_item_fields(contract \\ :current), do: Keyword.keys(line_item_properties(contract))

  @doc "The response schema with positional line-item arrays used by text and vision extraction."
  def tuple_schema(kind, contract \\ :current) do
    schema = object_schema(kind, contract)
    fields = line_item_fields(contract)

    reverse_charge = %{
      anyOf: [%{type: "boolean"}, %{type: "null"}],
      description:
        "True when the document explicitly states that tax is payable under reverse charge, including a statement below the tax summary. False only when it explicitly says reverse charge does not apply; null otherwise."
    }

    line_item = get_in(schema, [:properties, :line_items, :items])

    line_item_tuple = %{
      type: "array",
      prefixItems: Enum.map(fields, &Map.fetch!(line_item.properties, &1)),
      items: false,
      minItems: length(fields),
      maxItems: length(fields)
    }

    schema
    |> put_in([:properties, :line_items, :items], line_item_tuple)
    |> put_in([:properties, :reverse_charge], reverse_charge)
    |> update_in([:required], &(&1 ++ ["reverse_charge"]))
  end

  def decode_line_items(data, contract \\ :current) do
    fields = Enum.map(line_item_fields(contract), &to_string/1)

    Map.update!(data, "line_items", fn rows ->
      Enum.map(rows, fn values ->
        fields
        |> Enum.zip(values)
        |> Map.new()
        |> accounting_line(contract)
      end)
    end)
  end

  # Translate the model interface before shared repairs and verification read it.
  # Existing stored invoices and accounting code retain their current fields.
  defp accounting_line(line, :current), do: line

  defp accounting_line(line, :semantic) do
    line
    |> Map.put("printed_taxable_value", line["amount_before_gst"])
    |> Map.put("printed_line_total", line["amount_including_gst"])
    |> Map.put("printed_line_amount", nil)
    |> Map.put("line_amount_tax_inclusion", "unknown")
    |> Map.drop(["amount_before_gst", "amount_including_gst"])
  end

  defp invoice_properties(kind) do
    properties = %{
      document_type: %{
        type: "string",
        enum: ["invoice", "credit_note", "debit_note"],
        description:
          "Classify the document itself from its title and charging table. Footer terms that merely mention credit or debit notes do not change an invoice's type."
      },
      invoice_number:
        described_nullable(
          "string",
          "Printed invoice or note identifier, preserving punctuation but excluding its field label. Do not substitute a purchase-order, reference or delivery-document number. Return null if absent or unreadable."
        ),
      invoice_date:
        described_nullable(
          "string",
          "Printed issue date of this invoice or note. Preserve the printed date text without interpreting or reformatting it. Exclude due dates, purchase-order dates and delivery dates. Return null if absent or unreadable."
        ),
      line_items: %{
        type: "array",
        description:
          "One row per actual goods/services item. Text without its own serial number or amount is not a separate item; when structurally attached to the preceding item, append it to that item's description. Exclude totals, HSN summaries, tax recapitulations and amount-in-words rows.",
        items: line_item_schema()
      },
      printed_subtotal_before_discount:
        described_nullable(
          "number",
          "Literal goods/services subtotal printed before any discount. Copy it regardless of whether it includes GST; this field does not imply a taxable or tax-exclusive basis."
        ),
      printed_discount_amount:
        described_nullable(
          "number",
          "Total product/trade discount as a positive amount; null when no discount is printed."
        ),
      printed_total_taxable:
        described_nullable(
          "number",
          "Copy only a final invoice-level taxable turnover aggregate that is itself printed after discount. A subtotal labelled tax-inclusive and individual tax-rate or slab-summary taxable rows are not this aggregate. Return null when no invoice-level aggregate is printed; never select, combine or calculate one from item or summary rows."
        ),
      printed_tax_totals: printed_tax_totals_schema(),
      printed_additional_charges:
        described_nullable(
          "number",
          "A single invoice-level addition only when the document explicitly places that amount after GST in the total calculation. Do not infer that freight, packing, handling or another charge is post-GST, and do not combine separate charges unless their aggregate is itself printed."
        ),
      printed_rounding_adjustment:
        described_nullable(
          "number",
          "Signed printed rounding adjustment; negative when subtracted from the total."
        ),
      printed_grand_total:
        described_nullable(
          "number",
          "Printed Invoice Total or Amount Chargeable after applicable tax, charges and rounding. Exclude payments already made and the remaining balance due."
        )
    }

    Map.merge(properties, party_properties(kind))
  end

  defp party_properties(:purchase) do
    %{
      seller: purchase_party_schema(),
      buyer: basic_party_schema(),
      delivery_address: nullable("string")
    }
  end

  defp party_properties(:sales) do
    %{
      supplier: sales_party_schema(),
      bill_to: sales_party_schema(),
      ship_to: nullable_object(sales_party_properties()),
      recipient_registration: %{
        type: "string",
        enum: ["registered", "unregistered", "unknown"],
        description:
          "Whether the recipient is GST-registered. A printed GSTIN means registered. Use unregistered only when the document positively identifies an unregistered/consumer recipient; a missing or unreadable GSTIN alone means unknown."
      },
      document_status: %{
        type: "string",
        enum: ["active", "cancelled", "amendment", "unknown"],
        description:
          "Whether this is an active original document, a cancelled document, an amendment, or unclear. Do not treat a cancellation footer policy as the document's status."
      },
      supply_type: %{
        type: "string",
        enum: ["taxable", "nil_rated", "exempt", "non_gst", "export", "sez", "unknown"],
        description:
          "The supply treatment stated by the document. Ordinary GST-charged domestic supplies are taxable. Preserve nil-rated, exempt, non-GST, export and SEZ distinctions; use unknown when unclear."
      },
      tax_payment: %{
        type: "string",
        enum: ["with_payment", "without_payment", "unknown", "not_applicable"],
        description:
          "For export/SEZ: with_payment when explicitly on payment of IGST; without_payment when under LUT/bond without payment of IGST. Use unknown if unclear. Other supplies: not_applicable. Read the endorsement, not just the tax amounts."
      }
    }
  end

  defp purchase_party_schema do
    strict_object(%{
      name: nullable("string"),
      gstin: nullable("string"),
      address: nullable("string")
    })
  end

  defp basic_party_schema do
    strict_object(%{name: nullable("string"), gstin: nullable("string")})
  end

  defp sales_party_schema, do: strict_object(sales_party_properties())

  defp sales_party_properties do
    %{
      name: nullable("string"),
      gstin: nullable("string"),
      address: nullable("string"),
      state_code:
        described_nullable(
          "string",
          "GST state code explicitly printed for this party or address block; otherwise null."
        )
    }
  end

  defp line_item_schema(contract \\ :current),
    do: line_item_properties(contract) |> Map.new() |> strict_object()

  defp line_item_properties(:semantic) do
    current = line_item_properties(:current)

    Enum.take(current, 8) ++
      [
        amount_before_gst:
          described_nullable(
            "number",
            "Amount for the entire item quantity after item discount and before GST; null when absent or unclear."
          ),
        amount_including_gst:
          described_nullable(
            "number",
            "Amount for the entire item quantity after item discount and including GST; null when absent or unclear."
          )
      ] ++ Keyword.take(current, [:printed_tax_components, :repeat_count])
  end

  defp line_item_properties(:current) do
    [
      item_name:
        described_nullable(
          "string",
          "Primary printed product or service text in this item's name or description cell. Exclude supplementary notes or narrative from item_name; preserve them in description."
        ),
      description:
        described_nullable(
          "string",
          "Full printed line description, including supplementary narrative after the item name."
        ),
      hsn_sac:
        described_nullable(
          "string",
          "Copy this line's printed HSN/SAC, including codes in descriptions or service ledger names; otherwise null. Do not infer codes from product knowledge or use item identifiers."
        ),
      quantity: nullable("number"),
      uom: nullable("string"),
      printed_unit_price:
        described_nullable(
          "number",
          "Unit rate printed for this line. Copy it regardless of whether prices include GST; do not multiply it by quantity."
        ),
      discount_rate: described_nullable("number", "Printed percentage discount for this item."),
      discount_amount:
        described_nullable("number", "Discount amount subtracted from this item's list value."),
      printed_line_amount:
        described_nullable(
          "number",
          "Main printed amount for the entire item quantity. An amount explicitly labelled Taxable Value belongs in printed_taxable_value instead. A gross amount after separately printed tax for this item belongs in printed_line_total instead. Otherwise copy the row amount here, whether tax-inclusive or tax-exclusive. Footer taxes alone do not make it a printed_line_total. Exclude per-unit prices; null when no qualifying amount is printed."
        ),
      printed_line_total:
        described_nullable(
          "number",
          "Printed gross amount for the entire item quantity after tax separately shown for that item, including attached tax sub-rows. The heading may be Amount or Total. Footer taxes alone do not qualify. Return null when absent; this field can be populated while printed_line_amount is null."
        ),
      printed_taxable_value:
        described_nullable(
          "number",
          "Amount explicitly printed as this item's taxable value before GST for the entire quantity, even if it is the row's only extended amount. Exclude taxable price per unit, GST amounts and invoice subtotals. Assign this source amount here, not also to printed_line_amount. An ordinary tax-exclusive Amount cell belongs in printed_line_amount instead. Return null when no explicit extended taxable-value field is printed."
        ),
      line_amount_tax_inclusion: %{
        type: "string",
        enum: ["inclusive", "exclusive", "unknown"],
        description:
          "Whether printed_line_amount includes GST, inferred from labels, table structure or visible same-row arithmetic. Use unknown when printed_line_amount is null, or evidence is incomplete or conflicting. This field does not describe printed_line_total or printed_taxable_value. Invoice summaries, footer captions and amount-in-words labels do not determine line-amount inclusion."
      },
      printed_tax_components: printed_tax_components_schema(:line),
      repeat_count: %{
        type: "integer",
        minimum: 1,
        maximum: 1_000,
        description:
          "Number of consecutive identical printed rows represented by this tuple, including itself. Use more than 1 only when their other tuples are omitted from line_items."
      }
    ]
  end

  defp printed_tax_components_schema(:line) do
    %{
      type: "array",
      description:
        "Tax components printed for this item. Copy each label, rate and amount as printed; return an empty list when none is printed.",
      items:
        strict_object(%{
          printed_label:
            described_nullable(
              "string",
              "Literal item-level tax label, such as GST, IGST, CGST or SGST. Keep combined GST as one component; do not split it or copy footer tax heads into the item."
            ),
          printed_rate: described_nullable("number", "Tax rate printed for this component."),
          printed_amount: described_nullable("number", "Tax amount printed for this component.")
        })
    }
  end

  defp printed_tax_totals_schema do
    %{
      type: "array",
      description:
        "Invoice-level tax totals as printed, including separate tax-head totals and a generic Tax Amount or Total Tax. Copy each printed total once; return an empty list when none is printed.",
      items:
        strict_object(%{
          printed_label:
            described_nullable(
              "string",
              "Literal label printed for this invoice-level tax total."
            ),
          printed_amount: described_nullable("number", "Tax total printed with this label.")
        })
    }
  end

  defp nullable_object(properties) do
    %{anyOf: [strict_object(properties), %{type: "null"}]}
  end

  defp strict_object(properties) do
    %{
      type: "object",
      additionalProperties: false,
      properties: properties,
      required: properties |> Map.keys() |> Enum.map(&to_string/1)
    }
  end

  defp nullable(type), do: %{anyOf: [%{type: type}, %{type: "null"}]}

  defp described_nullable(type, description) do
    nullable(type) |> Map.put(:description, description)
  end
end
