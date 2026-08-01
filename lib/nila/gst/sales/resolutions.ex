defmodule Nila.Gst.Sales.Resolutions do
  @moduledoc """
  Append-only persistence for human decisions on a worked sales month's
  validation issues, and the single assembler that layers them over the
  engine's output. The outward mirror of `Nila.Gst.Purchase.Resolutions`.

  A sales month is rendered by `workings/1`: it takes the pristine stored
  invoices, folds in every resolution (`SalesWorkings.materialize`), and
  re-derives the portal-shaped return. Every surface — the month view, the
  portal JSON download, the 3B liability read — reads through this one
  function, so they cannot drift from the stored decisions.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Replay
  alias Nila.Gst.Sales.{Gstr1, Month, Resolution, Workings}
  alias Nila.Repo

  @doc "Resolutions for a sales month, oldest first (append-only replay order)."
  def list(sales_month_id) do
    Repo.all(
      from r in Resolution,
        where: r.sales_month_id == ^sales_month_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  @doc "Latest attributed resolution event for each target."
  def latest_decisions(sales_month_id) do
    Repo.all(
      from r in Resolution,
        where: r.sales_month_id == ^sales_month_id,
        order_by: [asc: r.inserted_at, asc: r.id],
        preload: [:decided_by]
    )
    |> Map.new(&{&1.target, &1})
  end

  @doc """
  Records one decision. `org_id` and `sales_month_id` are set on the struct,
  never cast (tenancy is not user-supplied). `decided_by_id` attributes the
  call. A new decision on a reviewed month demotes it back to "worked" — the
  review no longer covers the changed month. A *signed* month is a wall:
  decisions are rejected with `{:error, :signed_off}` until a senior reopens
  the GSTR-1 signature. Returns
  `{:ok, resolution} | {:error, :signed_off} | {:error, changeset}`.
  """
  def record(%Month{} = month, attrs, decided_by_id) do
    Repo.transact(fn ->
      month = lock_month(month)

      with :ok <- refuse_signed(month),
           {:ok, resolution} <-
             %Resolution{
               org_id: month.org_id,
               sales_month_id: month.id,
               decided_by_id: decided_by_id
             }
             |> Resolution.changeset(attrs)
             |> Repo.insert() do
        reopen_review(month)
        {:ok, resolution}
      end
    end)
  end

  defp refuse_signed(%Month{} = month) do
    case Signoffs.latest_gstr1_signoff(month.id) do
      {:ok, _signoff} -> {:error, :signed_off}
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  The effective outward month after every human resolution is applied over the
  engine's output: `%{invoices, issues, derived, decisions, silent_errors}`.
  This is the projection every sales surface renders.
  """
  def workings(%Month{} = month) do
    resolutions = month.id |> list() |> Enum.map(&resolution_map/1)

    Workings.materialize(
      month.invoices,
      resolutions,
      header(month),
      document_issues(month),
      source_namespace: "sales_month_#{month.id}"
    )
  end

  @doc """
  Diff-row targets (`"scope|key|field"`, the `Nila.Eval.Gstr1Diff` row key)
  whose difference a reviewer has accepted — filed differs, ours is right.
  Read directly off the append-only store, not through `workings/1`, so a
  signed month rendered from its snapshot still shows its confession sheet.
  """
  def accepted_differences(%Month{} = month) do
    month.id
    |> list()
    |> Enum.map(&resolution_map/1)
    |> Replay.decisions("target")
    |> Enum.filter(fn {_target, verb} -> verb == "accept_difference" end)
    |> MapSet.new(fn {target, _verb} -> target end)
  end

  # Issues about the packet rather than any invoice — the extraction ledger's
  # unread pages, and pages it read but could not render — can't be re-derived
  # from the invoices, so they carry over from what extraction recorded.
  @document_codes ~w(pages_unaccounted evidence_unavailable)

  defp document_issues(%Month{issues: issues}) when is_list(issues) do
    Enum.filter(issues, &(&1["invoice"] == nil and &1["code"] in @document_codes))
  end

  defp document_issues(_month), do: []

  @doc """
  Marks the month reviewed — the human has cleared every open issue, so 3B may
  assemble from this return as reviewed truth. Refuses while error-level issues
  remain open. Returns `{:ok, month} | {:error, :open_issues}`.
  """
  def mark_reviewed(%Month{} = month) do
    Repo.transact(fn ->
      month = lock_month(month)

      if Workings.reviewable?(workings(month).issues) do
        {:ok,
         month
         |> Month.changeset(%{state: "reviewed"})
         |> Repo.update!()}
      else
        {:error, :open_issues}
      end
    end)
  end

  @doc "Undoes the reviewed mark: further decisions re-open the month's review."
  def reopen_review(%Month{state: "reviewed"} = month) do
    month
    |> Month.changeset(%{state: "worked"})
    |> Repo.update!()
  end

  def reopen_review(%Month{} = month), do: month

  # Both review-state transitions re-read the month under a row lock: the
  # caller's struct may be stale, and reviewable-check + state flip (or
  # insert + demote) must be atomic against a concurrent reviewer.
  defp lock_month(%Month{id: id}) do
    Repo.one!(from m in Month, where: m.id == ^id, lock: "FOR UPDATE")
  end

  defp header(%Month{} = month) do
    {:ok, client} = Clients.get_client(month.org_id, month.client_id)
    Gstr1.production_header(client.gstin, month.period)
  end

  defp resolution_map(%Resolution{} = r) do
    %{"verb" => r.verb, "target" => r.target, "payload" => r.payload}
  end
end
