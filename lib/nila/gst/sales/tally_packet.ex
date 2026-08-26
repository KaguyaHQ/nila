defmodule Nila.Gst.Sales.TallyPacket do
  @moduledoc """
  The sales-bills handoff: effective sales invoices that can become Tally vouchers,
  the exact invoices held out, and the control totals for the generated XML.
  """

  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Hsn.Directory, as: HsnDirectory
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Issues
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Rates.Directory, as: RateDirectory

  alias Nila.Gst.Sales.{
    Gstr1,
    InvoiceCorrections,
    InvoiceReadiness,
    InvoiceRemovals,
    TallyReadiness
  }

  def fetch(org_id, client_id, batch_ref) do
    with {:ok, dump_ids} <- decode_ref(batch_ref),
         {:ok, dumps} <- Dumps.fetch_batch(org_id, client_id, dump_ids) do
      {:ok, dumps}
    end
  end

  def ref(dumps) when is_list(dumps), do: Enum.map_join(dumps, "-", & &1.id)

  def prepare(dumps) when is_list(dumps) do
    active = Enum.filter(dumps, &(&1.status == "extracted"))

    {all_invoices, source_invoices, excluded} =
      active
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)
      |> prepared_invoices(active, dumps)

    readiness = InvoiceReadiness.evaluate(source_invoices, compliance(active, source_invoices))
    source_invoices = readiness.invoices
    active_by_id = Map.new(source_invoices, &{Gstr1.source_id(&1), &1})

    all_invoices =
      Enum.map(all_invoices, fn invoice ->
        Map.get(active_by_id, Gstr1.source_id(invoice), invoice)
      end)

    warning_issues = Enum.filter(readiness.issues, &Issues.gating?/1)
    blocking_issues = TallyReadiness.issues(source_invoices)

    {invoices, warnings, blocked} = classify(source_invoices, warning_issues, blocking_issues)

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
      all_invoices: all_invoices,
      excluded: excluded,
      warnings: warnings,
      blocked: blocked,
      needs_review: warnings ++ blocked,
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

  defp prepared_invoices(invoices, [%Dump{org_id: org_id, client_id: client_id} | _], dumps) do
    if Enum.all?(dumps, &(&1.org_id == org_id and &1.client_id == client_id)) do
      batch_ref = ref(dumps)
      all_invoices = InvoiceCorrections.apply(org_id, client_id, batch_ref, invoices)

      {active, excluded} =
        InvoiceRemovals.partition_removed(org_id, client_id, batch_ref, all_invoices)

      {all_invoices, active, excluded}
    else
      {invoices, invoices, []}
    end
  end

  defp prepared_invoices(invoices, _active, _dumps), do: {invoices, invoices, []}

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
    source_id = Gstr1.source_id(invoice)

    Enum.filter(issues, fn issue ->
      issue["source_id"] == source_id or source_id in List.wrap(issue["source_ids"])
    end)
  end

  defp tally_export_issue(invoice, reason) do
    %{
      "invoice" => invoice["invoice_number"],
      "source_id" => Gstr1.source_id(invoice),
      "code" => "tally_export_failed",
      "message" => "Nila could not prepare this invoice as a Tally voucher.",
      "reason" => inspect(reason),
      "fields" => [],
      "level" => Issues.level_for("tally_export_failed")
    }
  end

  defp compliance([], _invoices), do: %{}

  defp compliance([%Dump{org_id: org_id, client_id: client_id} | _] = dumps, invoices) do
    %{}
    |> maybe_put_active_directory(:directory, HsnDirectory)
    |> maybe_put_active_directory(:rate_directory, RateDirectory)
    |> Map.put(
      :rate_history_by_period,
      rate_history_by_period(dumps, invoices, org_id, client_id)
    )
  end

  defp maybe_put_active_directory(compliance, key, directory_module) do
    case directory_module.active() do
      {:ok, directory} -> Map.put(compliance, key, directory)
      {:error, :not_found} -> compliance
    end
  end

  defp rate_history_by_period(dumps, invoices, org_id, client_id) do
    if Enum.all?(dumps, &(&1.org_id == org_id and &1.client_id == client_id)) do
      invoices
      |> Enum.map(&invoice_period/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Map.new(&{&1, RateHistory.prior_observations(org_id, client_id, &1)})
    else
      %{}
    end
  end

  defp invoice_period(%{"invoice_date" => %Date{} = date}),
    do: Calendar.strftime(date, "%Y-%m")

  defp invoice_period(%{
         "invoice_date" => <<year::binary-size(4), "-", month::binary-size(2), _rest::binary>>
       }),
       do: year <> "-" <> month

  defp invoice_period(_invoice), do: nil

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
