defmodule Nila.Gst.Sales.SourcePacket do
  @moduledoc "Effective sales sources and shared invoice checks before output-specific preparation."

  alias Nila.Gst.Hsn.Directory, as: HsnDirectory
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.RateHistory
  alias Nila.Gst.Rates.Directory, as: RateDirectory
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Gst.Sales.Invoice.Readiness, as: InvoiceReadiness
  alias Nila.Gst.Sales.Invoice.Removals, as: InvoiceRemovals

  def prepare(dumps) when is_list(dumps) do
    active = Enum.filter(dumps, &(&1.status == "extracted"))

    {all_invoices, invoices, excluded} =
      active
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)
      |> prepared_invoices(dumps)

    readiness = InvoiceReadiness.evaluate(invoices, compliance(dumps, invoices))
    active_by_id = Map.new(readiness.invoices, &{Invoice.source_id(&1), &1})

    %{
      invoices: readiness.invoices,
      all_invoices: Enum.map(all_invoices, &Map.get(active_by_id, Invoice.source_id(&1), &1)),
      source_issues: readiness.issues,
      excluded: excluded,
      failed_files: Enum.filter(dumps, &(&1.status == "failed")),
      unread_pages: unread_pages(active)
    }
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

  defp prepared_invoices([], _dumps), do: {[], [], []}

  defp prepared_invoices(invoices, [%Dump{org_id: org_id, client_id: client_id} | _] = dumps) do
    if Enum.all?(dumps, &(&1.org_id == org_id and &1.client_id == client_id)) do
      all_invoices = InvoiceCorrections.apply_sources(org_id, client_id, invoices)
      {active, excluded} = InvoiceRemovals.partition_removed(org_id, client_id, all_invoices)
      {all_invoices, active, excluded}
    else
      {invoices, invoices, []}
    end
  end

  defp prepared_invoices(invoices, []), do: {invoices, invoices, []}

  defp compliance(_dumps, []), do: %{}
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
end
