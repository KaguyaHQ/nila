defmodule Nila.Gst.Extraction.Discovery.DocumentPages do
  @moduledoc "Groups sales packet pages before routing documents for extraction."

  @types ~w(tax_invoice credit_note debit_note proforma_invoice quotation other)
  @sales_types ~w(tax_invoice credit_note debit_note)

  def schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["pages"],
      properties: %{
        pages: %{
          type: "array",
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["page", "page_role", "document_type", "invoice_no", "reason"],
            properties: %{
              page: %{type: "integer"},
              page_role: %{type: "string", enum: ~w(start continuation irrelevant unreadable)},
              document_type: %{anyOf: [%{type: "string", enum: @types}, %{type: "null"}]},
              invoice_no: %{anyOf: [%{type: "string"}, %{type: "null"}]},
              reason: %{anyOf: [%{type: "string"}, %{type: "null"}]}
            }
          }
        }
      }
    }
  end

  def prompt(page_count) do
    """
    Identify document boundaries in this ordered packet of Indian GST sales documents.
    Return exactly one entry per physical page, numbered 1 through #{page_count}.

    page_role and document_type are separate decisions:
    - start: begins a new document of ANY type, including a proforma or quotation.
      Set document_type to tax_invoice, credit_note, debit_note, proforma_invoice,
      quotation, or other. Use other for receipts, purchase orders and standalone challans.
    - continuation: belongs to the preceding document, INCLUDING its terms or signature
      pages. Set document_type to null; code inherits the preceding document's type.
    - irrelevant: blank or separator page, not part of a document. document_type is null.
    - unreadable: too damaged to determine the boundary. document_type is null.
    - A repeated seller alone is not evidence of continuation. Use document numbers,
      customer identity, explicit page numbering, continued tables and closing totals.
    - A different document number starts a new document. A repeated complete scan also
      starts a new document, even when the document number matches.
    - Explicit PROFORMA INVOICE headings mean proforma_invoice even with GST amounts.
      Its terms page is continuation, not a new tax invoice. A tax invoice merely
      referencing a quotation remains tax_invoice. TAX INVOICE CUM DELIVERY CHALLAN
      is a tax_invoice, not other.
    - invoice_no must be printed on that page itself; otherwise return null.
    Do not extract line items or totals. Return only the page decisions.
    """
  end

  def group(pages, expected_count) do
    expected = Enum.to_list(1..expected_count)
    actual = Enum.map(pages, & &1["page"])

    if actual == expected do
      pages
      |> Enum.reduce_while({:ok, []}, fn page, {:ok, segments} ->
        case append(page, segments) do
          {:ok, segments} -> {:cont, {:ok, segments}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, segments} -> {:ok, Enum.reverse(segments)}
        error -> error
      end
    else
      {:error, {:page_conservation, expected, actual}}
    end
  end

  defp append(%{"page_role" => "start", "document_type" => type} = page, segments)
       when type in @types do
    kind = if type in @sales_types, do: :invoice, else: :non_invoice
    {:ok, [segment(page, kind, type) | segments]}
  end

  defp append(%{"page_role" => "continuation", "document_type" => nil} = page, [open | rest])
       when open.document_type in @types do
    {:ok, [%{open | pages: open.pages ++ [page["page"]]} | rest]}
  end

  defp append(%{"page_role" => "continuation", "document_type" => nil} = page, _segments),
    do: {:error, {:document_continuation_without_start, page["page"]}}

  defp append(%{"page_role" => role, "document_type" => nil} = page, segments)
       when role in ["irrelevant", "unreadable"] do
    kind = if role == "unreadable", do: :unreadable, else: :non_invoice
    {:ok, [segment(page, kind, nil) | segments]}
  end

  defp append(page, _segments), do: {:error, {:invalid_document_page, page["page"]}}

  defp segment(page, kind, type) do
    %{
      pages: [page["page"]],
      kind: kind,
      document_type: type,
      invoice_no: page["invoice_no"],
      reason: page["reason"],
      issues: []
    }
  end
end
