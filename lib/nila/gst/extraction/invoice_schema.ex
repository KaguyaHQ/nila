defmodule Nila.Gst.Extraction.InvoiceSchema do
  @moduledoc """
  Provider-neutral schema for one extracted GST invoice.

  Keep semantic roles explicit here before compensating in prompts or adding
  confidence fields. Invoice-level tax totals remain distinct from summary rows,
  and sales parties remain split into Bill To and Ship To instead of asking the
  model to determine tax treatment from their addresses.
  """

  @doc "The structured schema shared by text and vision extraction."
  def invoice_schema(kind) when kind in [:purchase, :sales] do
    kind |> invoice_properties() |> strict_object()
  end

  defp invoice_properties(kind) do
    properties = %{
      document_type: %{
        type: "string",
        enum: ["invoice", "credit_note", "debit_note"],
        description:
          "Classify the document itself from its title and charging table. Footer terms that merely mention credit or debit notes do not change an invoice's type."
      },
      invoice_number: %{type: "string"},
      invoice_date: %{type: "string"},
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
          "Final printed amount payable after tax, charges and rounding."
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

  defp line_item_schema do
    strict_object(%{
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
          "The main extended amount printed for this whole line, regardless of the vendor's heading. This is not a unit rate and not the gross total after separately printed tax. Copy it whether tax-inclusive or tax-exclusive; null when no line amount is printed."
        ),
      printed_line_total:
        described_nullable(
          "number",
          "The gross total printed for this same item row after separately shown tax, regardless of the vendor's heading. Do not copy an invoice subtotal, grand total or amount-in-words value."
        ),
      printed_taxable_value:
        described_nullable(
          "number",
          "A distinct source field that separately prints this line's taxable value before GST. Do not duplicate printed_line_amount into this field merely because the line amount is tax-exclusive; return null when no separate taxable-value field is printed."
        ),
      line_amount_tax_inclusion: %{
        type: "string",
        enum: ["inclusive", "exclusive", "unknown"],
        description:
          "Whether printed_line_amount includes GST, inferred from labels, table structure or visible same-row arithmetic. Labels apply only at their structural scope; invoice summaries, footer captions and amount-in-words labels do not determine line-amount inclusion. Use unknown when evidence is incomplete or conflicting."
      },
      printed_tax_components: printed_tax_components_schema(:line),
      repeat_count: %{
        type: "integer",
        minimum: 1,
        maximum: 1_000,
        description:
          "Number of consecutive identical printed rows represented by this tuple, including itself. Use more than 1 only when their other tuples are omitted from line_items."
      }
    })
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
              "Literal tax type or tax-column label printed for this component, such as IGST, CGST or SGST."
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
