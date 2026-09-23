defmodule NilaWeb.Gst.HsnPresentation do
  @moduledoc "HSN summary rows and their source invoice contributors."
  alias Nila.Gst.Sales.{Invoice, Gstr1}

  @doc "Registered HSN contributor rows and unregistered aggregates for JSON presentation."
  def detail_rows(derived, invoices) do
    assigns = %{
      hsn:
        Gstr1.hsn_summary(
          Enum.filter(
            invoices,
            &(Invoice.recipient_registration(&1) == "registered" and
                not is_nil(Gstr1.filing_table(&1)))
          )
        ),
      buyers: buyers_by_inum(invoices),
      invoice_refs: invoice_refs_by_inum(invoices)
    }

    %{
      registered: hsn_rows(assigns),
      unregistered: get_in(derived || %{}, ["hsn", "hsn_b2c"]) || []
    }
  end

  defp hsn_node_id(row),
    do: dom_id("gstr1-workings-hsn-#{row["hsn_sc"] || "none"}-#{trim_rate(row["rt"])}")

  defp trim_rate(rate) when is_number(rate) do
    if rate == trunc(rate), do: trunc(rate), else: rate
  end

  defp trim_rate(rate), do: rate

  defp dom_id(raw), do: String.replace(raw, ~r/[^A-Za-z0-9]+/, "-")

  defp hsn_rows(assigns) do
    Enum.flat_map(assigns.hsn, fn row ->
      id = hsn_node_id(row)
      contribs = List.wrap(row["contribs"])

      node = %{
        kind: :node,
        id: id,
        hsn: row["hsn_sc"],
        description: row["description"],
        rate: row["rt"],
        count: length(contribs),
        taxable: row["txval"],
        tax: hsn_tax(row)
      }

      [node | contrib_rows(contribs, id, assigns.buyers, assigns.invoice_refs)]
    end)
  end

  defp contrib_rows(contribs, parent, buyers, invoice_refs) do
    map_with_inum_occurrence(contribs, fn contrib, occurrence ->
      ref = invoice_ref(invoice_refs, contrib["inum"], occurrence)

      %{
        kind: :contrib,
        id: contrib_id(parent, ref),
        parent: parent,
        inum: contrib["inum"],
        ref: ref,
        label: buyers[contrib["inum"]],
        taxable: contrib["txval"],
        tax: contrib["tax"]
      }
    end)
  end

  defp map_with_inum_occurrence(items, mapper) do
    {rows, _counts} =
      Enum.map_reduce(items, %{}, fn item, counts ->
        inum = item["inum"]
        occurrence = Map.get(counts, inum, 0)
        {mapper.(item, occurrence), Map.put(counts, inum, occurrence + 1)}
      end)

    rows
  end

  defp invoice_ref(invoice_refs, inum, occurrence) do
    case Map.get(invoice_refs, inum, []) do
      [_single] -> inum
      refs -> Enum.at(refs, occurrence, inum)
    end
  end

  defp contrib_id(parent, inum), do: dom_id("#{parent}-inv-#{inum}")

  defp detail_tax(row),
    do: (row["camt"] || 0) + (row["samt"] || 0) + (row["iamt"] || 0) + (row["csamt"] || 0)

  defp hsn_tax(row), do: detail_tax(row)

  # The rate and HSN aggregates know their contributors by invoice number; the
  # buyer is the label that makes a row recognisable, and it comes off the
  # invoice, not off any regrouping.
  defp buyers_by_inum(invoices) do
    Map.new(invoices, &{&1["invoice_number"], &1["buyer_name"]})
  end

  defp invoice_refs_by_inum(invoices) do
    Enum.group_by(invoices, & &1["invoice_number"], & &1["id"])
  end
end
