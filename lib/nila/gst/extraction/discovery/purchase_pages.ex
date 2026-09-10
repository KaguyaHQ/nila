defmodule Nila.Gst.Extraction.Discovery.PurchasePages do
  @moduledoc "Groups classified purchase pages into documents."

  def prompt(page_count) do
    """
    Label every page of this ordered packet of Indian GST purchase invoices.
    Return exactly one entry for every physical page, numbered 1 through #{page_count}.

    - start: this page begins a new invoice, credit note or debit note.
    - continuation: this page carries on the invoice from the preceding page.
    - non_invoice: standalone challan, e-way bill, purchase order, receipt, blank or separator.
    - unreadable: the image is too damaged to decide.
    - A repeated seller is not enough to join pages. Use document number, customer,
      explicit page numbering, continued item tables and closing totals.
    - A repeated complete scan is a new start even when its invoice number matches the
      preceding page. Only an incomplete document page can be a continuation.
    - invoice_no must be visible on that page itself; otherwise return null.
    Do not extract line items or totals. Return only the page labels.
    """
  end

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
            required: ["page", "label", "invoice_no", "reason"],
            properties: %{
              page: %{type: "integer"},
              label: %{
                type: "string",
                enum: ["start", "continuation", "non_invoice", "unreadable"]
              },
              invoice_no: %{anyOf: [%{type: "string"}, %{type: "null"}]},
              reason: %{anyOf: [%{type: "string"}, %{type: "null"}]}
            }
          }
        }
      }
    }
  end

  def group(pages, expected_count) do
    with {:ok, labels} <- decode_labels(pages, expected_count) do
      {:ok, stitch(labels)}
    end
  end

  @doc """
  Groups purchase pages in page order. A continuation joins the preceding invoice.
  An orphan continuation starts a group with a `continuation_without_start` issue.
  """
  def stitch(labels) do
    labels
    |> Enum.sort_by(& &1.page)
    |> Enum.reduce([], fn label, segments ->
      case {label.label, segments} do
        {:continuation, [%{kind: :invoice} = open | rest]} ->
          [%{open | pages: open.pages ++ [label.page]} | rest]

        {:continuation, segments} ->
          [
            new_segment(label, :invoice, [{:continuation_without_start, label.page}])
            | segments
          ]

        {:start, segments} ->
          [new_segment(label, :invoice, []) | segments]

        {kind, segments} ->
          [new_segment(label, kind, []) | segments]
      end
    end)
    |> Enum.reverse()
  end

  defp new_segment(label, kind, issues) do
    %{
      pages: [label.page],
      kind: kind,
      invoice_no: label.invoice_no,
      reason: label.reason,
      issues: issues
    }
  end

  defp decode_labels(pages, expected_count) do
    expected = Enum.to_list(1..expected_count)
    actual = Enum.map(pages, & &1["page"])

    if actual == expected do
      {:ok,
       Enum.map(pages, fn page ->
         %{
           page: page["page"],
           label: label(page["label"]),
           invoice_no: blank_to_nil(page["invoice_no"]),
           reason: blank_to_nil(page["reason"]),
           usage: %{}
         }
       end)}
    else
      {:error, {:page_conservation, expected, actual}}
    end
  end

  defp label("start"), do: :start
  defp label("continuation"), do: :continuation
  defp label("non_invoice"), do: :non_invoice
  defp label(_unreadable), do: :unreadable

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil
end
