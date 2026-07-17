defmodule Nila.Gst.Dumps do
  @moduledoc """
  Intake for a client's GST month: dumps arrive one at a time, each is
  recorded and extracted on its own, and the month is derived from the union.

  The shape follows how documents actually reach a firm: one main pile early,
  then stragglers — chase responses, forgotten bills — in ones and twos. Each
  arrival extracts only its own pages (the normalized invoices persist on the
  dump), so a two-bill straggler never re-reads the fifty-page main dump, and
  invoice ids from earlier dumps stay stable — which is what lets recorded
  resolutions survive accretion. GSTR-2B is the exception: it is a portal
  snapshot, whole and authoritative, so a new 2B *replaces* the old
  (superseded dumps keep their rows for audit but drop out of the effective
  set).
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Gst.Dump
  alias Nila.Repo

  @active_statuses ~w(received extracting)

  @doc """
  Records one arrival. Tenancy (`org_id`, `client_id`) and attribution
  (`brought_in_by_id`) are set on the struct, never cast.
  """
  def record(%{org_id: org_id, client_id: client_id} = scope, attrs) do
    %Dump{
      org_id: org_id,
      client_id: client_id,
      brought_in_by_id: scope[:brought_in_by_id]
    }
    |> Dump.changeset(attrs)
    |> Repo.insert()
  end

  @doc "All dumps for `(org, client, period)`, oldest first (arrival order)."
  def list(org_id, client_id, period) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.client_id == ^client_id and d.period == ^period,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  @doc "Non-terminal dumps for `(org, client, period)`, oldest first."
  def active(org_id, client_id, period) do
    Repo.all(
      from d in Dump,
        where:
          d.org_id == ^org_id and d.client_id == ^client_id and d.period == ^period and
            d.status in ^@active_statuses,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  @doc "All non-terminal dumps for an org, used to mark processing client-months."
  def active_for_org(org_id) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.status in ^@active_statuses,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  @doc "Fetches one dump scoped to the org. `{:error, :not_found}` otherwise."
  def fetch(org_id, dump_id) do
    Repo.fetch_by(Dump, id: dump_id, org_id: org_id)
  end

  @doc """
  The effective dump set for deriving a month: every extracted bill dump of
  `kind`, arrival order. For `"gstr2b"` the latest extracted dump alone — a
  2B snapshot replaces its predecessors.
  """
  def effective(org_id, client_id, period, "gstr2b") do
    org_id
    |> extracted(client_id, period, "gstr2b")
    |> Enum.take(-1)
  end

  def effective(org_id, client_id, period, kind) when kind in ~w(sales purchase) do
    extracted(org_id, client_id, period, kind)
  end

  @doc """
  The union of normalized invoices across the effective dumps of `kind`,
  arrival order. Invoice ids and image basenames were namespaced per-dump at
  extraction time, so the union is plain concatenation — nothing collides,
  nothing renumbers, and earlier resolutions stay valid when a straggler
  arrives.
  """
  def union_invoices(org_id, client_id, period, kind) do
    org_id
    |> effective(client_id, period, kind)
    |> Enum.flat_map(& &1.invoices)
    |> Enum.map(&rehydrate/1)
  end

  @doc """
  Restores types the JSONB round-trip flattens: `invoice_date` comes back an
  ISO string; the recon and flags expect `Date`. Applied on every read of a
  dump's invoices so downstream code sees the same shapes the extractors
  produced.
  """
  def rehydrate(invoice) do
    Map.update(invoice, "invoice_date", nil, fn
      %Date{} = date -> date
      value when is_binary(value) -> from_iso(value)
      other -> other
    end)
  end

  defp from_iso(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> value
    end
  end

  def mark_extracting(%Dump{} = dump),
    do: dump |> Dump.changeset(%{status: "extracting", error: nil}) |> Repo.update!()

  def mark_extracted(%Dump{} = dump, invoices, meta \\ %{}) do
    dump
    |> Dump.changeset(%{status: "extracted", invoices: invoices, meta: meta})
    |> Repo.update!()
  end

  def mark_failed(%Dump{} = dump, error),
    do: dump |> Dump.changeset(%{status: "failed", error: truncate(error)}) |> Repo.update!()

  def mark_held(%Dump{} = dump),
    do: dump |> Dump.changeset(%{status: "held"}) |> Repo.update!()

  @doc "Re-queues a held dump as received so a worker can derive it in."
  def release(%Dump{status: "held"} = dump),
    do: dump |> Dump.changeset(%{status: "received"}) |> Repo.update!()

  defp extracted(org_id, client_id, period, kind) do
    org_id
    |> list(client_id, period)
    |> Enum.filter(&(&1.kind == kind and &1.status == "extracted"))
  end

  defp truncate(error) do
    error |> to_string() |> String.slice(0, 500)
  end
end
