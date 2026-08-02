defmodule Nila.Gst.Sales.Months do
  @moduledoc """
  Persistence for a client's worked outward GST month: the extracted `invoices`,
  the `derived_gstr1` return, `issues`, and `summary` stored as JSON blobs (the
  outward mirror of `Nila.Gst.Purchase.Months`). Reads are always org-scoped so one
  firm can never see another's month.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Sales.Month
  alias Nila.Repo
  alias Nila.Storage

  @basename_format ~r/\A[\w-]+\.(png|jpg|jpeg|webp)\z/

  @doc """
  Lists an org's worked sales months, newest period first, with the client
  preloaded for display. Scoped to `org_id` so one firm never sees another's.
  """
  def list_for_org(org_id) do
    Repo.all(
      from sm in Month,
        where: sm.org_id == ^org_id,
        order_by: [desc: sm.period, desc: sm.inserted_at],
        preload: [:client]
    )
  end

  @doc """
  The most recent sales month per client for `org_id`, as a map of
  `client_id => %Month{}`. The outward mirror of
  `Nila.Gst.Purchase.Months.latest_by_client/1` — list screens need both sides
  to say where a client's month actually stands.
  """
  def latest_by_client(org_id) do
    Repo.all(
      from sm in Month,
        where: sm.org_id == ^org_id,
        order_by: [asc: sm.client_id, desc: sm.period, desc: sm.inserted_at],
        distinct: sm.client_id
    )
    |> Map.new(&{&1.client_id, &1})
  end

  @doc """
  Fetches the worked sales month for `client_id` in `period`, scoped to `org_id`.
  Returns `{:error, :not_found}` when it doesn't exist or belongs to another org.
  """
  def get_by_period(org_id, client_id, period) do
    Repo.fetch_by(Month, org_id: org_id, client_id: client_id, period: period)
  end

  @doc """
  Inserts or updates the sales month for `(org_id, client_id, period)`. `org_id`
  and `client_id` are set on the struct, never cast (tenancy is not
  user-supplied). Idempotent — safe to re-run a backfill.
  """
  def upsert(%{org_id: org_id, client_id: client_id, period: period} = attrs) do
    sales_month =
      case get_by_period(org_id, client_id, period) do
        {:ok, existing} -> existing
        {:error, :not_found} -> %Month{org_id: org_id, client_id: client_id}
      end

    sales_month
    |> Month.changeset(attrs)
    |> maybe_put_hsn_release(attrs)
    |> maybe_put_rate_release(attrs)
    |> Repo.insert_or_update()
  end

  defp maybe_put_hsn_release(changeset, %{hsn_master_release_id: release_id}),
    do: Ecto.Changeset.put_change(changeset, :hsn_master_release_id, release_id)

  defp maybe_put_hsn_release(changeset, _attrs), do: changeset

  defp maybe_put_rate_release(changeset, %{gst_rate_release_id: release_id}),
    do: Ecto.Changeset.put_change(changeset, :gst_rate_release_id, release_id)

  defp maybe_put_rate_release(changeset, _attrs), do: changeset

  @doc """
  Tenant-scoped storage key for one scanned sales bill. The key is derived from
  the ids the caller has already authorised — never from a raw filesystem path —
  so it cannot escape the `(org, client, period)` prefix.
  """
  def evidence_key(org_id, client_id, period, basename) do
    "orgs/#{org_id}/clients/#{client_id}/#{period}/evidence/gstr1/#{basename}"
  end

  @doc """
  Fetches one evidence image's bytes for `basename`, but only after proving the
  month belongs to `org_id`. A foreign org's `client_id` resolves to
  `{:error, :not_found}` before any storage read, so an org can never fetch
  another org's bills. `basename` is whitelisted to a bare filename to kill path
  traversal.
  """
  def fetch_evidence(org_id, client_id, period, basename) do
    with true <- valid_basename?(basename),
         {:ok, _month} <- get_by_period(org_id, client_id, period),
         {:ok, bytes} <- Storage.get(evidence_key(org_id, client_id, period, basename)) do
      {:ok, bytes}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp valid_basename?(basename) when is_binary(basename),
    do: Regex.match?(@basename_format, basename)

  defp valid_basename?(_), do: false

  @doc """
  Subscribes the caller to an org's sales-month-processing progress. The upload
  LiveView subscribes here so it can narrate the (minutes-long) extraction wait.
  """
  def subscribe(org_id) do
    Phoenix.PubSub.subscribe(Nila.PubSub, topic(org_id))
  end

  @doc """
  Broadcasts a sales-month-processing progress message to an org's subscribers.
  Called by `Nila.Gst.Intake.DumpWorker` at each stage.
  """
  def broadcast_progress(org_id, message) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic(org_id), message)
  end

  defp topic(org_id), do: "gstr1_month:#{org_id}"
end
