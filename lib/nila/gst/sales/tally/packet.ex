defmodule Nila.Gst.Sales.Tally.Packet do
  @moduledoc """
  The sales-bills handoff: effective sales invoices that can become Tally vouchers,
  the exact invoices held out, and the control totals for the generated XML.
  """

  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Batch, Invoice, SourcePacket}
  alias Nila.Gst.Sales.Tally.Readiness, as: TallyReadiness

  defdelegate fetch(org_id, client_id, batch_ref), to: Batch
  defdelegate fetch_with_record(org_id, client_id, batch_ref), to: Batch
  defdelegate ref(dumps), to: Batch
  defdelegate original_name(dump), to: SourcePacket

  def prepare(dumps, opts \\ []) when is_list(dumps) do
    dumps |> SourcePacket.prepare(opts) |> from_source()
  end

  @doc "Applies Tally capability checks to an already prepared sales source packet."
  def from_source(packet) do
    source_invoices = packet.invoices

    warning_issues =
      packet.source_issues
      |> Enum.filter(&TallyReadiness.relevant_invoice_issue?/1)
      |> Enum.filter(&Issues.gating?/1)

    blocking_issues = TallyReadiness.issues(source_invoices)

    {invoices, warnings, blocked} = classify(source_invoices, warning_issues, blocking_issues)

    totals =
      Enum.reduce(invoices, %{taxable_paise: 0, tax_paise: 0}, fn invoice, totals ->
        amounts = Invoice.extracted_totals_paise(invoice)

        %{
          taxable_paise: totals.taxable_paise + (amounts.taxable_paise || 0),
          tax_paise: totals.tax_paise + amounts.tax_paise
        }
      end)

    Map.merge(totals, %{
      invoices: invoices,
      all_invoices: packet.all_invoices,
      source_issues: packet.source_issues,
      excluded: packet.excluded,
      warnings: warnings,
      blocked: blocked,
      needs_review: warnings ++ blocked,
      failed_files: packet.failed_files,
      unread_pages: packet.unread_pages
    })
  end

  def build_xml(dumps) when is_list(dumps) do
    packet = prepare(dumps)
    TallyPrime.build(%{active_invoices: packet.invoices})
  end

  defp classify(invoices, warning_issues, blocking_issues) do
    invoices
    |> Enum.reduce({[], [], []}, fn invoice, {sendable, warnings, blocked} ->
      invoice_warnings = issues_for_invoice(warning_issues, invoice)
      invoice_blockers = issues_for_invoice(blocking_issues, invoice)

      cond do
        invoice_blockers != [] ->
          {sendable, warnings, [%{invoice: invoice, issues: invoice_blockers} | blocked]}

        true ->
          case TallyPrime.build(%{active_invoices: [invoice]}) do
            {:ok, _xml} when invoice_warnings == [] ->
              {[invoice | sendable], warnings, blocked}

            {:ok, _xml} ->
              {[invoice | sendable], [%{invoice: invoice, issues: invoice_warnings} | warnings],
               blocked}

            {:error, reason} ->
              issue = tally_export_issue(invoice, reason)

              {sendable, warnings,
               [%{invoice: invoice, issues: invoice_warnings ++ [issue]} | blocked]}
          end
      end
    end)
    |> then(fn {sendable, warnings, blocked} ->
      {Enum.reverse(sendable), Enum.reverse(warnings), Enum.reverse(blocked)}
    end)
  end

  defp issues_for_invoice(issues, invoice) do
    source_id = Invoice.source_id(invoice)

    Enum.filter(issues, fn issue ->
      issue["source_id"] == source_id or source_id in List.wrap(issue["source_ids"])
    end)
  end

  defp tally_export_issue(invoice, reason) do
    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => Invoice.source_id(invoice),
      "code" => "tally_export_failed",
      "message" => "Nila could not prepare this invoice as a Tally voucher.",
      "reason" => inspect(reason),
      "fields" => [],
      "level" => Issues.level_for("tally_export_failed")
    }
  end
end
