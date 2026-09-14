defmodule Nila.Gst.Sales.Processing do
  @moduledoc "Saved invoice discovery and completed reads for an unfinished sales file."
  import Ecto.Query, only: [from: 2]
  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Sales.{Month, Months}
  alias Nila.Repo

  def source_id(dump, ordinal),
    do: "d#{dump.id}_inv_#{String.pad_leading(to_string(ordinal), 2, "0")}"

  def snapshot(dump), do: (dump.meta || %{})["processing"] || %{}

  def discover(dump, segments) do
    update(dump, fn current ->
      state = snapshot(current)
      Map.merge(state, %{"segments" => segments, "failed" => []})
    end)
  end

  def failed(dump, ordinal) do
    update(dump, fn current ->
      Map.update(snapshot(current), "failed", [ordinal], &Enum.uniq([ordinal | &1]))
    end)
  end

  def complete(dump, invoice, artifact, ordinal) do
    # Review decisions need a month identity, but unfinished invoices stay out of
    # its stored totals. The review page overlays them only while reviewing.
    Repo.insert!(
      %Month{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "collecting"
      },
      on_conflict: :nothing,
      conflict_target: [:client_id, :period]
    )

    {:ok, result} =
      Repo.transact(fn ->
        current = Repo.one!(from d in Dump, where: d.id == ^dump.id, lock: "FOR UPDATE")
        state = snapshot(current)
        artifacts = Map.put(state["artifacts"] || %{}, to_string(ordinal), artifact)
        invoices = Enum.reject(current.invoices, &(&1["id"] == invoice["id"])) ++ [invoice]
        state = Map.put(state, "artifacts", artifacts)

        {:ok,
         current
         |> Dump.changeset(%{
           invoices: invoices,
           meta: Map.put(current.meta, "processing", state)
         })
         |> Repo.update!()}
      end)

    result
  end

  defp update(dump, fun) do
    {:ok, result} =
      Repo.transact(fn ->
        current = Repo.one!(from d in Dump, where: d.id == ^dump.id, lock: "FOR UPDATE")

        {:ok,
         current
         |> Dump.changeset(%{meta: Map.put(current.meta, "processing", fun.(current))})
         |> Repo.update!()}
      end)

    result
  end

  def reviewable?(dump), do: dump.status in ~w(extracted extracting received failed)

  def review_month(month) do
    if month.filed_at do
      month
    else
      pending =
        Nila.Gst.Intake.Dumps.list(month.org_id, month.client_id, month.period)
        |> Enum.filter(&(&1.status in ~w(extracting received failed)))
        |> Enum.flat_map(fn dump ->
          Enum.sort_by(dump.invoices, &(&1["source_pages"] || []))
        end)

      %{
        month
        | invoices:
            Enum.uniq_by((month.invoices || []) ++ pending, &Nila.Gst.Sales.Invoice.source_id/1)
      }
    end
  end

  def review_workings(org_id, client_id, period) do
    with {:ok, month} <- Months.get_by_period(org_id, client_id, period) do
      {:ok, Nila.Gst.Sales.Review.Resolutions.workings(review_month(month))}
    end
  end
end
