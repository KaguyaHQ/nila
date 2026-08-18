defmodule Nila.Gst.PeriodClients do
  @moduledoc """
  Clients with a real GST work surface in a given period.

  A client-month exists once either worked side or any intake dump exists. The
  switcher uses this same boundary as `MonthLive`, so every option it offers is
  a valid destination rather than a link that bounces the reviewer away.
  """

  import Ecto.Query

  alias Nila.Clients.Client
  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Purchase.Month, as: PurchaseMonth
  alias Nila.Gst.Sales.Month, as: SalesMonth
  alias Nila.Repo

  @doc "Returns the org-scoped clients that have work in `period`, filtered by name."
  def list(org_id, period, query \\ "") do
    purchase_ids =
      from month in PurchaseMonth,
        where: month.org_id == ^org_id and month.period == ^period,
        select: month.client_id

    sales_ids =
      from month in SalesMonth,
        where: month.org_id == ^org_id and month.period == ^period,
        select: month.client_id

    dump_ids =
      from dump in Dump,
        where: dump.org_id == ^org_id and dump.period == ^period,
        select: dump.client_id

    client_ids = purchase_ids |> union(^sales_ids) |> union(^dump_ids)

    Client
    |> where([client], client.org_id == ^org_id)
    |> where([client], client.id in subquery(client_ids))
    |> maybe_search(query)
    |> order_by([client], asc: client.name)
    |> Repo.all()
  end

  defp maybe_search(query, value) when value in [nil, ""], do: query

  defp maybe_search(query, value) do
    pattern = "%#{String.trim(value)}%"
    where(query, [client], ilike(client.name, ^pattern))
  end
end
