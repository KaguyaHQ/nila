defmodule Nila.Gst.Sales.Gstr1.Documents do
  @moduledoc """
  Reads document-number series for review controls and the GSTR-1 documents
  issued section. Parsing and gap accounting share the same series rules.
  """

  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.Invoice

  @doc """
  The invoice-number series as extraction read it: `from`/`to` bound the run,
  `missing` names the gaps and `duplicates` the numbers issued twice, each
  carrying the series suffix, ready to print. `nil` when no invoice number
  parses. Non-numeric document numbers still count in the issued-documents section.

  The account block and the fold's summary line render this, and
  `sequence_gaps` is raised from the same reading, so the sentence a reviewer
  is shown and the issue that demands his decision can never name different
  gaps.
  """
  def account(invoices) do
    accounts =
      invoices
      |> Enum.filter(&(Invoice.document_type(&1) == "invoice"))
      |> series_accounts()

    case Enum.max_by(accounts, & &1.count, fn -> nil end) do
      nil ->
        nil

      primary ->
        primary
        |> Map.put(:missing, Enum.flat_map(accounts, & &1.missing))
        |> Map.put(:duplicates, Enum.flat_map(accounts, & &1.duplicates))
        |> Map.delete(:count)
    end
  end

  def issues(invoices) do
    missing =
      invoices
      |> Enum.filter(&(Invoice.document_type(&1) == "invoice"))
      |> series_accounts()
      |> Enum.flat_map(& &1.missing)

    if missing == [] do
      []
    else
      [
        %{
          "invoice" => nil,
          "code" => "sequence_gaps",
          "level" => Issues.level_for("sequence_gaps"),
          "message" =>
            "missing/cancelled inferred from sequence: #{Enum.join(missing, ", ")} — confirm cancellation records",
          "fields" => ["doc_issue"]
        }
      ]
    end
  end

  def derive(invoices) do
    groups =
      [
        {1, Enum.filter(invoices, &(Invoice.document_type(&1) == "invoice"))},
        {4, Enum.filter(invoices, &(Invoice.document_type(&1) == "debit_note"))},
        {5, Enum.filter(invoices, &(Invoice.document_type(&1) == "credit_note"))}
      ]
      |> Enum.flat_map(fn {doc_num, documents} ->
        numbered = build_doc_issue_rows(parsed_series(documents))

        unnumbered =
          documents
          |> Enum.map(&Invoice.document_number/1)
          |> Enum.reject(&(&1 in [nil, ""] or not is_nil(parse_invoice_number(&1))))
          |> Enum.uniq()

        cancelled_unnumbered =
          Enum.count(unnumbered, fn number ->
            documents
            |> Enum.filter(&(Invoice.document_number(&1) == number))
            |> Enum.all?(&(Invoice.document_status(&1) == "cancelled"))
          end)

        rows =
          case unnumbered do
            [] ->
              numbered

            numbers ->
              numbered ++
                [
                  %{
                    "num" => length(numbered) + 1,
                    "from" => hd(numbers),
                    "to" => List.last(numbers),
                    "totnum" => length(numbers),
                    "net_issue" => length(numbers) - cancelled_unnumbered,
                    "cancel" => cancelled_unnumbered
                  }
                ]
          end

        case rows do
          [] -> []
          rows -> [%{"doc_num" => doc_num, "docs" => rows}]
        end
      end)

    %{"doc_det" => groups}
  end

  defp build_doc_issue_rows(series) do
    series
    |> Enum.with_index(1)
    |> Enum.map(fn {parsed, index} ->
      numbers = Enum.map(parsed, & &1.number)

      active_numbers =
        parsed
        |> Enum.reject(& &1.cancelled)
        |> Enum.map(& &1.number)
        |> Enum.uniq()

      min = Enum.min(numbers)
      max = Enum.max(numbers)
      first = hd(parsed)
      totnum = max - min + 1
      net_issue = length(active_numbers)

      %{
        "num" => index,
        "from" => format_series_number(min, first),
        "to" => format_series_number(max, first),
        "totnum" => totnum,
        "cancel" => totnum - net_issue,
        "net_issue" => net_issue
      }
    end)
  end

  defp normalize_invoice_number(invoice_number) do
    invoice_number
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s*\/\s*/, "/")
  end

  # The series reading, shared by `account/1` (what a reviewer is shown)
  # and `derive/1` (what gets filed as doc_det). Two copies meant the
  # printed sentence and the filed table could in principle read the series
  # differently.
  defp parsed_numbers(invoices) do
    invoices
    |> Enum.map(fn invoice ->
      case parse_invoice_number(invoice["invoice_number"]) do
        nil -> nil
        parsed -> Map.put(parsed, :cancelled, Invoice.document_status(invoice) == "cancelled")
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parsed_series(documents) do
    documents
    |> parsed_numbers()
    |> Enum.group_by(&{&1.prefix, &1.suffix})
    |> Enum.sort_by(fn {key, _parsed} -> key end)
    |> Enum.map(&elem(&1, 1))
  end

  defp series_accounts(documents) do
    Enum.map(parsed_series(documents), fn parsed ->
      numbers = Enum.map(parsed, & &1.number)
      first = hd(parsed)
      min = Enum.min(numbers)
      max = Enum.max(numbers)

      %{
        from: format_series_number(min, first),
        to: format_series_number(max, first),
        missing: Enum.map(Enum.to_list(min..max) -- numbers, &format_series_number(&1, first)),
        duplicates:
          (numbers -- Enum.uniq(numbers))
          |> Enum.uniq()
          |> Enum.map(&format_series_number(&1, first)),
        count: length(parsed)
      }
    end)
  end

  defp parse_invoice_number(nil), do: nil

  defp parse_invoice_number(invoice_number) do
    normalized = normalize_invoice_number(invoice_number)

    case Regex.run(~r/^(\d+)(.*)$/, normalized) do
      [_, number, suffix] ->
        parsed_invoice_number("", number, suffix)

      _prefixed ->
        case Regex.run(~r/^(.*\D)(\d+)(\D*)$/, normalized) do
          [_, prefix, number, suffix] -> parsed_invoice_number(prefix, number, suffix)
          _unparseable -> nil
        end
    end
  end

  defp parsed_invoice_number(prefix, number, suffix) do
    %{
      prefix: prefix,
      number: String.to_integer(number),
      width: String.length(number),
      suffix: suffix
    }
  end

  defp format_series_number(number, parsed) do
    parsed.prefix <> String.pad_leading(to_string(number), parsed.width, "0") <> parsed.suffix
  end

  def sort_key(invoice_number) do
    case parse_invoice_number(invoice_number) do
      %{number: number} -> number
      nil -> 999_999
    end
  end
end
