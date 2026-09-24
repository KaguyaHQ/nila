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
           {:ok, _owned_dumps} <- Batch.fetch(org_id, client_id, batch_ref),
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
           {:ok, _owned_dumps} <- Batch.fetch(org_id, client_id, batch_ref),
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

  @doc "Removes or restores selected sources atomically; originals and correction history remain."
  def change_upload(scope, client_id, period, ref, action, source_ids)
      when action in ["remove", "restore"] and is_list(source_ids) and source_ids != [] do
    if Nila.Accounts.Policy.can?(scope, :edit_records) do
      Repo.transact(fn ->
        org_id = scope.current_org.id
        # Lock every affected month before any dump, including cross-month projections.
        months =
          Repo.all(
            from m in Nila.Gst.Sales.Month,
              where: m.org_id == ^org_id and m.client_id == ^client_id,
              order_by: m.id,
              lock: "FOR UPDATE"
          )

        with {:ok, initial} <- Batch.fetch(org_id, client_id, ref) do
          ids = Enum.map(initial, & &1.id)

          dumps =
            Repo.all(
              from d in Nila.Gst.Intake.Dump,
                where: d.id in ^ids,
                order_by: d.id,
                lock: "FOR UPDATE"
            )

          all_ids = for d <- dumps, i <- d.invoices, do: Invoice.source_id(i)
          batch_ids = Enum.map(dumps, & &1.sales_batch_id) |> Enum.reject(&is_nil/1)

          affected =
            Enum.filter(months, fn m ->
              m.period == period or Enum.any?(m.invoices, &(Invoice.source_id(&1) in source_ids))
            end)

          cond do
            Enum.any?(
              dumps,
              &(&1.client_id != client_id or &1.org_id != org_id or &1.period != period or
                    &1.kind != "sales")
            ) ->
              {:error, :not_found}

            Enum.any?(source_ids, &(&1 not in all_ids)) ->
              {:error, :not_found}

            Enum.any?(affected, &(&1.filed_at != nil or &1.state == "filed")) ->
              {:error, :filed}

            Repo.exists?(
              from b in Batch, where: b.id in ^batch_ids and not is_nil(b.tally_company_id)
            ) or
                Repo.exists?(from j in Nila.TallyJobs.Job, where: j.sales_batch_id in ^batch_ids) ->
              {:error, :posted}

            Enum.any?(dumps, &(&1.status != "extracted")) or
                Repo.exists?(
                  from j in Oban.Job,
                    where: j.state in ["available", "scheduled", "executing", "retryable"],
                    where: fragment("?->>'dump_id'", j.args) in ^Enum.map(ids, &to_string/1)
                ) ->
              {:error, :processing}

            true ->
              existing = removed_ids(org_id, client_id, source_ids)

              changed =
                Enum.filter(Enum.uniq(source_ids), fn id ->
                  if action == "remove",
                    do: not MapSet.member?(existing, id),
                    else: MapSet.member?(existing, id)
                end)

              for id <- changed do
                if action == "remove" do
                  {:ok, _, _} =
                    record_removal(org_id, client_id, Batch.ref(dumps), id, scope.user.id)
                else
                  Repo.delete_all(
                    from r in InvoiceRemoval,
                      where:
                        r.org_id == ^org_id and r.client_id == ^client_id and r.source_id == ^id
                  )
                end
              end

              for dump <- dumps do
                local_ids =
                  Enum.filter(changed, fn id ->
                    Enum.any?(dump.invoices, &(Invoice.source_id(&1) == id))
                  end)

                if local_ids != [] do
                  event = %{
                    "action" => action,
                    "source_ids" => local_ids,
                    "actor_id" => scope.user.id,
                    "at" => DateTime.to_iso8601(DateTime.utc_now())
                  }

                  meta =
                    Map.update(dump.meta || %{}, "removal_history", [event], &(&1 ++ [event]))

                  dump |> Ecto.Changeset.change(meta: meta) |> Repo.update!()
                end
              end

              if changed != [], do: SourceChanges.invalidate_reviews(affected, scope.user.id)
              {:ok, %{ok: true}}
          end
        end
      end)
    else
      {:error, :read_only}
    end
  end

  def change_upload(_, _, _, _, _, _), do: {:error, :invalid}

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
      Nila.Gst.Sales.Processing.reviewable?(dump) and
        Enum.any?(dump.invoices, &(Invoice.source_id(Dumps.rehydrate(&1)) == source_id))
    end)
  end
end
