defmodule NilaWeb.Gst.InvoiceWorkbench do
  @moduledoc "Period context for the shared source-invoice editor."

  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Batch, Invoice, Months, Resolutions, Review}

  def load(org_id, client_id, period, source_id, scope) do
    with {:ok, month} <- Months.get_by_period(org_id, client_id, period) do
      workings = Resolutions.workings(month)
      review = Review.build(workings)
      item = Review.lookup(review.all, source_id)
      scope = if scope in ["needs_you", :needs_you], do: :needs_you, else: :all

      {:ok,
       %{
         month: month,
         workings: workings,
         review: review,
         item: item,
         scope: scope,
         queue: Review.scope(review, scope)
       }}
    end
  end

  # Only real, authorised source documents can open the editable workbench.
  # Historical imported workings may have no source batch.
  def path(org_id, client_id, period, source_id, scope, return_to \\ nil) do
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

      params = %{item: source_id, period: period, scope: scope}
      params = if return_to, do: Map.put(params, :return_to, return_to), else: params
      "/sales-bills/#{client_id}/batch/#{batch_ref}?#{URI.encode_query(params)}"
    end
  end

  def return_path(client_id, period, return_to) do
    base = "/gst/#{client_id}/#{period}/sales"

    if is_binary(return_to) && (return_to == base || String.starts_with?(return_to, base <> "/")),
      do: return_to,
      else: base <> "/invoices"
  end
end
