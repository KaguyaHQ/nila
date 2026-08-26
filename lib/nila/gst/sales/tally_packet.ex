defmodule Nila.Gst.Sales.TallyPacket do
  @moduledoc """
  The sales-bills handoff: effective sales invoices that can become Tally vouchers,
  the exact invoices held out, and the control totals for the generated XML.
  """

  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, InvoiceCorrections, InvoiceRemovals}

  def fetch(org_id, client_id, batch_ref) do
    with {:ok, dump_ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, dump_ids) do
      {:ok, dumps}
    end
  end

  def ref(dumps) when is_list(dumps), do: Enum.map_join(dumps, "-", & &1.id)

  def prepare(dumps) when is_list(dumps) do
    active = Enum.filter(dumps, &(&1.status == "extracted"))

    source_invoices =
      active
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)
      |> effective_invoices(active, dumps)

    issues =
      source_invoices
      |> Gstr1.validation_issues()
      |> Enum.concat(Gstr1.blocking_issues(source_invoices))
      |> Issues.normalize_all()
      |> Enum.filter(&Issues.gating?/1)

    {invoices, needs_review} = classify(source_invoices, issues)

    totals =
      Enum.reduce(invoices, %{taxable_paise: 0, tax_paise: 0}, fn invoice, totals ->
        amounts = Gstr1.extracted_totals(invoice)

        %{
          taxable_paise: totals.taxable_paise + paise(amounts.taxable),
          tax_paise: totals.tax_paise + paise(amounts.tax)
        }
      end)

    Map.merge(totals, %{
      invoices: invoices,
      all_invoices: source_invoices,
      needs_review: needs_review,
      excluded: Enum.map(needs_review, & &1.invoice),
      failed_files: Enum.reject(dumps, &(&1.status == "extracted")),
      unread_pages: unread_pages(active)
    })
  end

  def build_xml(dumps) when is_list(dumps) do
    packet = prepare(dumps)
    TallyPrime.build(%{active_invoices: packet.invoices})
  end

  def original_name(%Dump{meta: meta, id: id}) do
    Map.get(meta || %{}, "original_name") || "File ##{id}"
  end

  defp unread_pages(dumps) do
    for dump <- dumps,
        page <- Map.get(dump.meta || %{}, "unaccounted_pages", []) do
      %{file: original_name(dump), page: page}
    end
  end

  defp effective_invoices(invoices, [%Dump{org_id: org_id, client_id: client_id} | _], dumps) do
    if Enum.all?(dumps, &(&1.org_id == org_id and &1.client_id == client_id)) do
      batch_ref = ref(dumps)

      org_id
      |> InvoiceCorrections.apply(client_id, batch_ref, invoices)
      |> then(&InvoiceRemovals.reject_removed(org_id, client_id, batch_ref, &1))
    else
      invoices
    end
  end

  defp effective_invoices(invoices, _active, _dumps), do: invoices

  defp classify(invoices, issues) do
    invoices
    |> Enum.reduce({[], []}, fn invoice, {ready, needs_review} ->
      invoice_issues = issues_for_invoice(issues, invoice)

      case TallyPrime.build(%{active_invoices: [invoice]}) do
        {:ok, _xml} ->
          {[invoice | ready], needs_review}

        {:error, _reason} ->
          review_issues =
            if invoice_issues == [], do: [tally_export_issue(invoice)], else: invoice_issues

          {ready, [%{invoice: invoice, issues: review_issues} | needs_review]}
      end
    end)
    |> then(fn {ready, needs_review} ->
      {Enum.reverse(ready), Enum.reverse(needs_review)}
    end)
  end

  defp issues_for_invoice(issues, invoice) do
    source_id = Gstr1.source_id(invoice)

    Enum.filter(issues, fn issue ->
      issue["source_id"] == source_id or source_id in List.wrap(issue["source_ids"])
    end)
  end

  defp tally_export_issue(invoice) do
    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => Gstr1.source_id(invoice),
      "code" => "tally_export_failed",
      "message" => "Nila could not prepare this invoice as a Tally voucher.",
      "fields" => [],
      "level" => Issues.level_for("tally_export_failed")
    }
  end

  defp decode_ref(batch_ref) when is_binary(batch_ref) do
    ids =
      batch_ref
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if ids != [] and Enum.all?(ids, &match?({_, ""}, &1)) do
      {:ok, Enum.map(ids, &elem(&1, 0))}
    else
      {:error, :not_found}
    end
  end

  defp decode_ref(_batch_ref), do: {:error, :not_found}

  defp paise(value) when is_number(value), do: round(value * 100)
  defp paise(_value), do: 0
end
