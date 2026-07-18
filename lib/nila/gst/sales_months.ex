defmodule Nila.Gst.SalesMonths do
  @moduledoc """
  Persistence for a client's worked outward GST month: the extracted `invoices`,
  the `derived_gstr1` return, `issues`, and `summary` stored as JSON blobs (the
  outward mirror of `Nila.Gst.ClientMonths`). Reads are always org-scoped so one
  firm can never see another's month.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.SalesMonth
  alias Nila.Repo
  alias Nila.Storage

  @basename_format ~r/\A[\w-]+\.(png|jpg|jpeg|webp)\z/

  @doc """
  Lists an org's worked sales months, newest period first, with the client
  preloaded for display. Scoped to `org_id` so one firm never sees another's.
  """
  def list_for_org(org_id) do
    Repo.all(
      from sm in SalesMonth,
        where: sm.org_id == ^org_id,
        order_by: [desc: sm.period, desc: sm.inserted_at],
        preload: [:client]
    )
  end

  @doc """
  Fetches the worked sales month for `client_id` in `period`, scoped to `org_id`.
  Returns `{:error, :not_found}` when it doesn't exist or belongs to another org.
  """
  def get_by_period(org_id, client_id, period) do
    Repo.fetch_by(SalesMonth, org_id: org_id, client_id: client_id, period: period)
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
        {:error, :not_found} -> %SalesMonth{org_id: org_id, client_id: client_id}
      end

    sales_month
    |> SalesMonth.changeset(attrs)
    |> Repo.insert_or_update()
  end

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
  Called by `Nila.Gst.DumpWorker` at each stage.
  """
  def broadcast_progress(org_id, message) do
    Phoenix.PubSub.broadcast(Nila.PubSub, topic(org_id), message)
  end

  defp topic(org_id), do: "gstr1_month:#{org_id}"
end
