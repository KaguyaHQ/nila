defmodule Nila.Gst.Purchase.Months do
  @moduledoc """
  Persistence for a client's worked GST month: the engine's `register_rows`,
  `recon`, and `summary` stored as JSON blobs (mirrors `document_artifacts.data`
  — the row shape is still fluid, so we don't normalise rows into their own
  table yet). Reads are always org-scoped so one firm can never see another's
  month.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Purchase.{ItcCases, Month}
  alias Nila.Repo
  alias Nila.Storage

  @basename_format ~r/\A[\w-]+\.(png|jpg|jpeg|webp)\z/

  @doc """
  Lists an org's worked months, newest period first, with the client preloaded
  for display. Scoped to `org_id` so one firm never sees another's months.
  """
  def list_for_org(org_id) do
    Repo.all(
      from cm in Month,
        where: cm.org_id == ^org_id,
        order_by: [desc: cm.period, desc: cm.inserted_at],
        preload: [:client]
    )
  end

  @doc """
  The most recent month per client for `org_id`, as a map of
  `client_id => %Month{}`. Powers list screens that show each client's
  latest work without loading every month.
  """
  def latest_by_client(org_id) do
    Repo.all(
      from cm in Month,
        where: cm.org_id == ^org_id,
        order_by: [asc: cm.client_id, desc: cm.period, desc: cm.inserted_at],
        distinct: cm.client_id
    )
    |> Map.new(&{&1.client_id, &1})
  end

  @doc """
  Fetches the worked month for `client_id` in `period`, scoped to `org_id`.
  Returns `{:error, :not_found}` when it doesn't exist or belongs to another org.
  """
  def get_by_period(org_id, client_id, period) do
    Repo.fetch_by(Month, org_id: org_id, client_id: client_id, period: period)
  end

  @doc "Fetches an org-scoped worked month with its client preloaded."
  def get_by_period_with_client(org_id, client_id, period) do
    Repo.fetch_one(
      from cm in Month,
        where: cm.org_id == ^org_id and cm.client_id == ^client_id and cm.period == ^period,
        preload: [:client]
    )
  end

  @doc """
  Inserts or updates the month for `(org_id, client_id, period)`. `org_id` and
  `client_id` are set on the struct, never cast (tenancy is not user-supplied).
  Idempotent — safe to re-run a backfill.
  """
  def upsert(attrs) do
    Repo.transact(fn -> upsert_in_transaction(attrs) end)
  end

  def upsert_in_transaction(%{org_id: org_id, client_id: client_id, period: period} = attrs) do
    client_month =
      case get_by_period(org_id, client_id, period) do
        {:ok, existing} -> existing
        {:error, :not_found} -> %Month{org_id: org_id, client_id: client_id}
      end

    result =
      client_month
      |> Month.changeset(attrs)
      |> maybe_put_hsn_release(attrs)
      |> maybe_put_rate_release(attrs)
      |> Repo.insert_or_update()

    with {:ok, month} <- result,
         :ok <- ItcCases.sync_month(month, month.recon) do
      {:ok, month}
    end
  end

  defp maybe_put_hsn_release(changeset, %{hsn_master_release_id: release_id}),
    do: Ecto.Changeset.put_change(changeset, :hsn_master_release_id, release_id)

  defp maybe_put_hsn_release(changeset, _attrs), do: changeset

  defp maybe_put_rate_release(changeset, %{gst_rate_release_id: release_id}),
    do: Ecto.Changeset.put_change(changeset, :gst_rate_release_id, release_id)

  defp maybe_put_rate_release(changeset, _attrs), do: changeset

  @doc """
  Tenant-scoped storage key for one scanned bill. The key is derived from the
  ids the caller has already authorised — never from a raw filesystem path — so
  it cannot escape the `(org, client, period)` prefix.
  """
  def evidence_key(org_id, client_id, period, basename) do
    "orgs/#{org_id}/clients/#{client_id}/#{period}/evidence/#{basename}"
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
  Subscribes the caller to an org's month-processing progress. The upload
  LiveView subscribes here so it can narrate the (minutes-long) extraction wait.
  """
  def subscribe(org_id) do
    Phoenix.PubSub.subscribe(Nila.PubSub, topic(org_id))
  end

  @doc """
  Broadcasts a month-processing progress message to an org's subscribers.
  Called by `Nila.Gst.Intake.DumpWorker` at each stage.
  """
  def broadcast_progress(org_id, message) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic(org_id), message)
  end

  defp topic(org_id), do: "gst_month:#{org_id}"
end
