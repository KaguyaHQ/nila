defmodule Nila.Gst.Sales.Review.Resolutions do
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
  alias Nila.Gst.Hsn.Directory
  alias Nila.Gst.Replay
  alias Nila.Gst.Sales.{Gstr1, Month, Workings}
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Gst.Sales.Review.Resolution
  alias Nila.Gst.Sales.Tally.Register, as: TallyRegister
  alias Nila.Repo

  @doc "Current sales workings, or the recorded snapshot for an already filed month."
  def effective_workings(%Month{filed_at: nil} = month), do: workings(month)

  def effective_workings(%Month{} = month) do
    invoices = month.invoices || []
    active = Enum.reject(invoices, & &1["duplicate_copy"])

    %{
      derived: month.derived_gstr1,
      contributions: %{},
      invoices: invoices,
      source_invoices: invoices,
      active_invoices: active,
      printed_active_invoices: nil,
      issues: Nila.Gst.Issues.normalize_all(month.issues || []),
      flagged: MapSet.new()
    }
  end

  @doc "Resolutions for a sales month, oldest first (append-only replay order)."
  def list(sales_month_id) do
    Repo.all(
      from r in Resolution,
        where: r.sales_month_id == ^sales_month_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  @doc "Resolution events for a sales month with their reviewer attribution."
  def list_attributed(sales_month_id) do
    sales_month_id
    |> list()
    |> Repo.preload(:decided_by)
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
  review no longer covers the changed month. Filed months retain their recorded
  history and reject changes with `{:error, :filed}`.
  """
  def record(%Month{} = month, attrs, decided_by_id) do
    Repo.transact(fn ->
      month = lock_month(month)

      with :ok <- refuse_filed(month),
           :ok <- reject_direct_duplicate_exclusion(attrs),
           {:ok, resolution} <-
             %Resolution{
               org_id: month.org_id,
               sales_month_id: month.id,
               decided_by_id: decided_by_id
             }
             |> Resolution.changeset(attrs)
             |> Repo.insert() do
        reopen_review(month)
        Signoffs.invalidate_gstr3b_in_transaction(month, decided_by_id)
        {:ok, resolution}
      end
    end)
  end

  @doc "Marks every other member of one duplicate-number group as source copies."
  def exclude_duplicate_copies(%Month{} = month, retained_source_id, decided_by_id) do
    Repo.transact(fn ->
      month = lock_month(month)

      with :ok <- refuse_filed(month),
           {:ok, copies} <- duplicate_copies_for(workings(month), retained_source_id) do
        resolutions =
          Enum.map(copies, fn copy ->
            %Resolution{
              org_id: month.org_id,
              sales_month_id: month.id,
              decided_by_id: decided_by_id
            }
            |> Resolution.changeset(%{
              "verb" => "exclude_duplicate_copy",
              "target" => "duplicate_copy|#{copy["id"]}",
              "payload" => %{
                "excluded_source_id" => copy["id"],
                "retained_source_id" => retained_source_id,
                "reason" => "Reviewer confirmed both sources are copies of the same invoice",
                "outcome" => "same_invoice_uploaded_twice"
              }
            })
            |> Repo.insert!()
          end)

        reopen_review(month)
        Signoffs.invalidate_gstr3b_in_transaction(month, decided_by_id)
        {:ok, resolutions}
      end
    end)
  end

  @doc "Restores one source previously excluded as a duplicate copy."
  def restore_duplicate_copy(%Month{} = month, source_id, decided_by_id) do
    if Enum.any?(workings(month).duplicate_copies, &(&1["id"] == source_id)) do
      record(
        month,
        %{"verb" => "reopen", "target" => "duplicate_copy|#{source_id}"},
        decided_by_id
      )
    else
      {:error, :not_duplicate_copy}
    end
  end

  defp duplicate_copies_for(workings, retained_source_id) do
    with %{} = retained <-
           Enum.find(workings.active_invoices, &(&1["id"] == retained_source_id)),
         number when is_binary(number) and number != "" <- retained["invoice_number"],
         members <- Enum.filter(workings.active_invoices, &(&1["invoice_number"] == number)),
         true <- length(members) > 1 do
      {:ok, Enum.reject(members, &(&1["id"] == retained_source_id))}
    else
      _invalid -> {:error, :not_duplicate_group}
    end
  end

  defp reject_direct_duplicate_exclusion(attrs) do
    if (attrs["verb"] || attrs[:verb]) == "exclude_duplicate_copy",
      do: {:error, :use_duplicate_resolution},
      else: :ok
  end

  defp refuse_filed(%Month{filed_at: nil}), do: :ok
  defp refuse_filed(%Month{}), do: {:error, :filed}

  @doc """
  The effective outward month after every human resolution is applied over the
  engine's output: `%{invoices, issues, derived, decisions, silent_errors}`.
  This is the projection every sales surface renders.
  """
  def workings(%Month{} = month) do
    resolutions = month.id |> list() |> Enum.map(&resolution_map/1)
    tally = TallyRegister.project(month)

    invoices =
      InvoiceCorrections.apply_sources(month.org_id, month.client_id, tally.invoices)
      |> then(&Nila.Gst.Sales.Invoice.Removals.active_sources(month.org_id, month.client_id, &1))

    workings =
      Workings.materialize(
        invoices,
        resolutions,
        header(month),
        document_issues(month) ++ tally.issues,
        source_namespace: "sales_month_#{month.id}",
        compliance: compliance(month)
      )

    Map.put(workings, :source_summary, tally.summary)
  end

  defp compliance(%Month{} = month) do
    directory =
      case month.hsn_master_release_id do
        nil -> Directory.active()
        release_id -> Directory.load(release_id)
      end

    case directory do
      {:ok, directory} -> %{directory: directory}
      {:error, :not_found} -> %{}
    end
  end

  @doc """
  Diff-row targets (`"scope|key|field"`, the `Nila.Eval.Gstr1Diff` row key)
  whose difference a reviewer has accepted — filed differs, ours is right.
  Read directly off the append-only store, not through `workings/1`, so a
  filed month rendered from its snapshot still shows its recorded differences.
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
