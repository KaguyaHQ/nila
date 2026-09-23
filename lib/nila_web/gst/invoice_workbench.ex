defmodule NilaWeb.Gst.InvoiceWorkbench do
  @moduledoc "Authorised source batch lookup for React invoice review."

  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Batch, Invoice}

  def source_batch(org_id, client_id, period, source_id) do
    dump =
      Dumps.list(org_id, client_id, period)
      |> Enum.find(fn dump ->
        dump.sales_batch_id &&
          Enum.any?(dump.invoices || [], &(Invoice.source_id(&1) == source_id))
      end)

    if dump do
      {:ok, batch, _} = Batch.fetch_with_record(org_id, client_id, to_string(dump.id))

      batch_ref =
        batch
        |> Nila.Repo.preload(:dumps)
        |> Map.fetch!(:dumps)
        |> Enum.sort_by(& &1.id)
        |> Batch.ref()

      %{batch_ref: batch_ref, dump: dump}
    end
  end
end
