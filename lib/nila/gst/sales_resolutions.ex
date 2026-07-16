defmodule Nila.Gst.SalesResolutions do
  @moduledoc """
  Append-only persistence for human decisions on a worked sales month's
  validation issues, and the single assembler that layers them over the
  engine's output. The outward mirror of `Nila.Gst.Resolutions`.

  A sales month is rendered by `workings/1`: it takes the pristine stored
  invoices, folds in every resolution (`SalesWorkings.materialize`), and
  re-derives the portal-shaped return. Every surface — the month view, the
  portal JSON download, the 3B liability read — reads through this one
  function, so they cannot drift from the stored decisions.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients
  alias Nila.Gst.{Gstr1, SalesMonth, SalesResolution, SalesWorkings}
  alias Nila.Repo

  @doc "Resolutions for a sales month, oldest first (append-only replay order)."
  def list(sales_month_id) do
    Repo.all(
      from r in SalesResolution,
        where: r.sales_month_id == ^sales_month_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  @doc """
  Records one decision. `org_id` and `sales_month_id` are set on the struct,
  never cast (tenancy is not user-supplied). `decided_by_id` attributes the
  call. A new decision on a reviewed month demotes it back to "worked" — the
  review no longer covers the changed month. Returns
  `{:ok, resolution} | {:error, changeset}`.
  """
  def record(%SalesMonth{} = month, attrs, decided_by_id) do
    Repo.transact(fn ->
      with {:ok, resolution} <-
             %SalesResolution{
               org_id: month.org_id,
               sales_month_id: month.id,
               decided_by_id: decided_by_id
             }
             |> SalesResolution.changeset(attrs)
             |> Repo.insert() do
        month |> lock_month() |> reopen_review()
        {:ok, resolution}
      end
    end)
  end

  @doc """
  The effective outward month after every human resolution is applied over the
  engine's output: `%{invoices, issues, derived, decisions, silent_errors}`.
  This is the projection every sales surface renders.
  """
  def workings(%SalesMonth{} = month) do
    resolutions = month.id |> list() |> Enum.map(&resolution_map/1)
    SalesWorkings.materialize(month.invoices, resolutions, header(month))
  end

  @doc """
  Marks the month reviewed — the human has cleared every open issue, so 3B may
  assemble from this return as reviewed truth. Refuses while error-level issues
  remain open. Returns `{:ok, month} | {:error, :open_issues}`.
  """
  def mark_reviewed(%SalesMonth{} = month) do
    Repo.transact(fn ->
      month = lock_month(month)

      if SalesWorkings.reviewable?(workings(month).issues) do
        {:ok,
         month
         |> SalesMonth.changeset(%{state: "reviewed"})
         |> Repo.update!()}
      else
        {:error, :open_issues}
      end
    end)
  end

  @doc "Undoes the reviewed mark: further decisions re-open the month's review."
  def reopen_review(%SalesMonth{state: "reviewed"} = month) do
    month
    |> SalesMonth.changeset(%{state: "worked"})
    |> Repo.update!()
  end

  def reopen_review(%SalesMonth{} = month), do: month

  # Both review-state transitions re-read the month under a row lock: the
  # caller's struct may be stale, and reviewable-check + state flip (or
  # insert + demote) must be atomic against a concurrent reviewer.
  defp lock_month(%SalesMonth{id: id}) do
    Repo.one!(from m in SalesMonth, where: m.id == ^id, lock: "FOR UPDATE")
  end

  defp header(%SalesMonth{} = month) do
    {:ok, client} = Clients.get_client(month.org_id, month.client_id)
    Gstr1.production_header(client.gstin, month.period)
  end

  defp resolution_map(%SalesResolution{} = r) do
    %{"verb" => r.verb, "target" => r.target, "payload" => r.payload}
  end
end
