defmodule Nila.Gst.Extraction.DocumentPagesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Discovery.DocumentPages

  defp page(number, role, type \\ nil, invoice_no \\ nil) do
    %{
      "page" => number,
      "page_role" => role,
      "document_type" => type,
      "invoice_no" => invoice_no,
      "reason" => nil
    }
  end

  test "continuations inherit excluded and sales document types without merging boundaries" do
    assert {:ok, [quotation, invoice, credit, debit]} =
             DocumentPages.group(
               [
                 page(1, "start", "quotation", "Q-1"),
                 page(2, "continuation"),
                 page(3, "start", "tax_invoice", "INV-1"),
                 page(4, "continuation"),
                 page(5, "start", "credit_note", "CN-1"),
                 page(6, "continuation"),
                 page(7, "start", "debit_note", "DN-1")
               ],
               7
             )

    assert quotation.kind == :non_invoice
    assert quotation.pages == [1, 2]
    assert invoice.kind == :invoice
    assert invoice.pages == [3, 4]
    assert credit.document_type == "credit_note"
    assert credit.kind == :invoice
    assert credit.pages == [5, 6]
    assert debit.kind == :invoice
    assert debit.pages == [7]
  end

  test "an orphan continuation is rejected, including after a separator or unreadable page" do
    assert {:error, {:document_continuation_without_start, 1}} =
             DocumentPages.group([page(1, "continuation")], 1)

    for role <- ["irrelevant", "unreadable"] do
      assert {:error, {:document_continuation_without_start, 3}} =
               DocumentPages.group(
                 [page(1, "start", "proforma_invoice"), page(2, role), page(3, "continuation")],
                 3
               )
    end
  end

  test "a continuation cannot override its parent type and a start must identify its type" do
    assert {:error, {:invalid_document_page, 2}} =
             DocumentPages.group(
               [
                 page(1, "start", "proforma_invoice"),
                 page(2, "continuation", "tax_invoice")
               ],
               2
             )

    assert {:error, {:invalid_document_page, 1}} = DocumentPages.group([page(1, "start")], 1)
  end

  test "conserves page order and rejects omitted, duplicate and out-of-order pages" do
    for numbers <- [[1], [1, 1], [2, 1]] do
      assert {:error, {:page_conservation, [1, 2], ^numbers}} =
               DocumentPages.group(Enum.map(numbers, &page(&1, "start", "tax_invoice")), 2)
    end
  end

  test "a repeated complete document remains a separate group" do
    assert {:ok, [first, second]} =
             DocumentPages.group(
               [
                 page(1, "start", "tax_invoice", "INV-1"),
                 page(2, "start", "tax_invoice", "INV-1")
               ],
               2
             )

    assert first.pages == [1]
    assert second.pages == [2]
  end
end
