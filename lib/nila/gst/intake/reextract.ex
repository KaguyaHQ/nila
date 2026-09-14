defmodule Nila.Gst.Intake.Reextract do
  @moduledoc """
  Internal, synchronous reread of an untouched, extracted sales upload.

      Nila.Gst.Intake.Reextract.run(org_id, dump_id)

  Keeps the original upload and records extraction attempts through the normal
  extractor. Failed reads leave the saved answer untouched. Human decisions,
  reviewed/filed months, and concurrent changes prevent replacement. No UI or
  automatic retries: callers receive `{:ok, dump}` or `{:error, reason}`;
  unexpected extractor/storage exceptions propagate without replacing the answer.
  Conservatively refuses any decisions in the affected month, even on other bills,
  and sources reused in another month. Recheck eligibility after the slow read.
  """
  import Ecto.Query
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias Nila.Gst.Sales.Month
  alias Nila.Gst.Sales.Invoice.{Correction, Removal}
  alias Nila.Gst.Sales.Review.Resolution
  alias Nila.Repo

  def run(org_id, dump_id) when is_integer(org_id) and is_integer(dump_id) do
    with {:ok, snapshot} <- Dumps.fetch(org_id, dump_id),
         {:ok, snapshot} <- checked(snapshot, fn dump -> {:ok, dump} end),
         {:ok, candidate} <- DumpWorker.reread_sales(snapshot),
         :ok <- complete(candidate) do
      checked(snapshot, fn dump ->
        DumpWorker.promote_sales_reread(dump, candidate)
      end)
    end
  end

  defp complete(candidate) do
    if candidate.invoices == [] or candidate.meta["evidence_unavailable"] or
         candidate.meta["unaccounted_pages"] != [] do
      {:error, :incomplete_read}
    else
      :ok
    end
  end

  defp checked(snapshot, action) do
    Repo.transact(fn ->
      # Same order as source edits: months, then upload. Never hold locks over Qwen.
      months =
        Repo.all(
          from m in Month,
            where: m.org_id == ^snapshot.org_id and m.client_id == ^snapshot.client_id,
            order_by: m.id,
            lock: "FOR UPDATE"
        )

      dump =
        Repo.one(
          from d in Dump,
            where: d.id == ^snapshot.id and d.org_id == ^snapshot.org_id,
            lock: "FOR UPDATE"
        )

      with :ok <- unchanged(dump, snapshot),
           :ok <- eligible(dump, months) do
        action.(dump)
      end
    end)
  end

  defp unchanged(nil, _), do: {:error, :not_found}
  defp unchanged(dump, dump), do: :ok
  defp unchanged(_, _), do: {:error, :upload_changed}

  defp eligible(%Dump{kind: "sales", status: "extracted"} = dump, months) do
    ids = Enum.map(dump.invoices, &(&1["id"] || &1["invoice_number"]))

    affected =
      Enum.filter(months, fn month ->
        month.period == dump.period or
          Enum.any?(month.invoices, &((&1["id"] || &1["invoice_number"]) in ids))
      end)

    month_ids = Enum.map(affected, & &1.id)

    cond do
      Enum.any?(affected, &(&1.state in ["reviewed", "filed"] or not is_nil(&1.filed_at))) ->
        {:error, :reviewed_or_filed}

      Enum.any?(affected, &(&1.period != dump.period)) ->
        {:error, :used_in_another_month}

      Repo.exists?(from r in Resolution, where: r.sales_month_id in ^month_ids) ->
        {:error, :human_decisions}

      Repo.exists?(
        from c in Correction,
          where:
            c.org_id == ^dump.org_id and c.client_id == ^dump.client_id and c.source_id in ^ids
      ) ->
        {:error, :human_decisions}

      Repo.exists?(
        from r in Removal,
          where:
            r.org_id == ^dump.org_id and r.client_id == ^dump.client_id and r.source_id in ^ids
      ) ->
        {:error, :human_decisions}

      true ->
        :ok
    end
  end

  defp eligible(_, _), do: {:error, :not_extracted_sales}
end
