defmodule Nila.Gst.Sales.SourcePacket do
  @moduledoc "Effective sales sources and shared invoice checks before output-specific preparation."

  alias Nila.Gst.Hsn.Directory, as: HsnDirectory
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.Invoice
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Gst.Sales.Invoice.Readiness, as: InvoiceReadiness
  alias Nila.Gst.Sales.Invoice.Removals, as: InvoiceRemovals

  def prepare(dumps, opts \\ []) when is_list(dumps) do
    active_statuses =
      if Keyword.get(opts, :include_processing, false),
        do: ["extracted", "extracting", "received", "failed"],
        else: ["extracted"]

    active = Enum.filter(dumps, &(&1.status in active_statuses))

    {all_invoices, invoices, excluded} =
      active
      |> Enum.flat_map(& &1.invoices)
      |> Enum.map(&Dumps.rehydrate/1)
      |> prepared_invoices(dumps)

    readiness =
      InvoiceReadiness.evaluate(
        invoices,
        Map.put(compliance(), :taxpayers, Nila.Gst.Sales.TaxpayerChecks.saved(invoices))
      )

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

  defp compliance do
    case HsnDirectory.active() do
      {:ok, directory} -> %{directory: directory}
      {:error, :not_found} -> %{}
    end
  end
end
