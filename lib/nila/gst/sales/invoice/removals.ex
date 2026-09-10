defmodule Nila.Gst.Sales.Invoice.Removals do
  @moduledoc "Internal tombstones for invoices removed from active sales work."

  import Ecto.Query

  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Batch, Invoice}
  alias Nila.Gst.Sales.Invoice.Removal, as: InvoiceRemoval
  alias Nila.Gst.Sales.Invoice.SourceChanges
  alias Nila.Repo

  def remove(org_id, client_id, batch_ref, source_id, removed_by_id)
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) and is_integer(removed_by_id) do
    Repo.transact(fn ->
      with :ok <- validate_remover(org_id, removed_by_id),
           {:ok, dumps} <- Batch.fetch(org_id, client_id, batch_ref),
           true <- Enum.all?(dumps, &(&1.kind == "sales")),
           canonical_ref = Batch.ref(dumps),
           true <- source_invoice?(dumps, source_id),
           {:ok, months} <- SourceChanges.lock(org_id, client_id, source_id),
           {:ok, removal, changed?} <-
             record_removal(org_id, client_id, canonical_ref, source_id, removed_by_id) do
        if changed?, do: SourceChanges.invalidate_reviews(months, removed_by_id)
        {:ok, removal}
      else
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def remove(_org_id, _client_id, _batch_ref, _source_id, _removed_by_id),
    do: {:error, :not_found}

  def restore(org_id, client_id, batch_ref, source_id, restored_by_id)
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) and is_integer(restored_by_id) do
    Repo.transact(fn ->
      with :ok <- validate_remover(org_id, restored_by_id),
           {:ok, dumps} <- Batch.fetch(org_id, client_id, batch_ref),
           true <- Enum.all?(dumps, &(&1.kind == "sales")),
           true <- source_invoice?(dumps, source_id),
           {:ok, months} <- SourceChanges.lock(org_id, client_id, source_id),
           {count, _} when count > 0 <-
             Repo.delete_all(
               from removal in InvoiceRemoval,
                 where:
                   removal.org_id == ^org_id and removal.client_id == ^client_id and
                     removal.source_id == ^source_id
             ) do
        SourceChanges.invalidate_reviews(months, restored_by_id)
        {:ok, :restored}
      else
        false -> {:error, :not_found}
        {0, _} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def restore(_org_id, _client_id, _batch_ref, _source_id, _restored_by_id),
    do: {:error, :not_found}

  defp record_removal(org_id, client_id, batch_ref, source_id, removed_by_id) do
    existing =
      Repo.one(
        from removal in InvoiceRemoval,
          where:
            removal.org_id == ^org_id and removal.client_id == ^client_id and
              removal.source_id == ^source_id,
          order_by: removal.id,
          limit: 1
      )

    if existing do
      {:ok, existing, false}
    else
      with {:ok, removal} <-
             %InvoiceRemoval{org_id: org_id, client_id: client_id, removed_by_id: removed_by_id}
             |> InvoiceRemoval.changeset(%{
               batch_ref: batch_ref,
               source_id: source_id,
               removed_at: DateTime.utc_now()
             })
             |> Repo.insert() do
        {:ok, removal, true}
      end
    end
  end

  def partition_removed(org_id, client_id, invoices)
      when is_integer(org_id) and is_integer(client_id) and is_list(invoices) do
    source_ids = Enum.map(invoices, &Invoice.source_id/1)
    removed_ids = removed_ids(org_id, client_id, source_ids)
    Enum.split_with(invoices, &(not MapSet.member?(removed_ids, Invoice.source_id(&1))))
  end

  def partition_removed(_org_id, _client_id, invoices) when is_list(invoices),
    do: {invoices, []}

  defp removed_ids(_org_id, _client_id, []), do: MapSet.new()

  defp removed_ids(org_id, client_id, source_ids) do
    Repo.all(
      from removal in InvoiceRemoval,
        where:
          removal.org_id == ^org_id and removal.client_id == ^client_id and
            removal.source_id in ^source_ids,
        select: removal.source_id
    )
    |> MapSet.new()
  end

  @doc "Excludes tombstoned source invoices from period workings without deleting evidence."
  def active_sources(org_id, client_id, invoices) do
    {active, _removed} = partition_removed(org_id, client_id, invoices)
    active
  end

  defp validate_remover(org_id, user_id) do
    if Repo.exists?(
         from membership in Nila.Orgs.Membership,
           where: membership.org_id == ^org_id and membership.user_id == ^user_id
       ) do
      :ok
    else
      {:error, :remover_not_in_org}
    end
  end

  defp source_invoice?(dumps, source_id) do
    Enum.any?(dumps, fn dump ->
      dump.status == "extracted" and
        Enum.any?(dump.invoices, &(Invoice.source_id(Dumps.rehydrate(&1)) == source_id))
    end)
  end
end
