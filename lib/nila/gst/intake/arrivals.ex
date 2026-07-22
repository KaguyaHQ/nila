defmodule Nila.Gst.Intake.Arrivals do
  import Ecto.Query

  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Arrival, Dump, Dumps, DumpWorker}
  alias Nila.Repo
  alias Nila.Storage

  def ingest(%{org_id: org_id} = scope, attrs) do
    source = Map.fetch!(attrs, :source)
    source_ref = Map.get(attrs, :source_ref)

    case existing(org_id, source, source_ref) do
      %Arrival{} = arrival ->
        {:ok, arrival}

      nil ->
        filename = attrs |> Map.fetch!(:filename) |> Path.basename() |> safe_filename()
        bytes = Map.fetch!(attrs, :bytes)
        content_type = Map.get(attrs, :content_type, "application/octet-stream")
        key = storage_key(org_id, content_type)
        {:ok, _stored} = Storage.put(key, bytes, content_type: content_type)

        result =
          %Arrival{org_id: org_id, client_id: scope[:client_id]}
          |> Arrival.changeset(%{
            source: source,
            source_ref: source_ref,
            sender: Map.fetch!(attrs, :sender),
            storage_key: key,
            filename: filename,
            content_type: content_type,
            received_at: Map.get(attrs, :received_at, DateTime.utc_now()),
            status: "pending"
          })
          |> Repo.insert()

        case result do
          {:ok, arrival} ->
            broadcast(org_id)
            {:ok, arrival}

          {:error, changeset} ->
            case existing(org_id, source, source_ref) do
              %Arrival{} = arrival ->
                {:ok, arrival}

              nil ->
                :ok = Storage.delete(key)
                {:error, changeset}
            end
        end
    end
  end

  def pending_for_org(org_id) do
    Repo.all(
      from arrival in Arrival,
        where: arrival.org_id == ^org_id and arrival.status == "pending",
        order_by: [desc: arrival.received_at, desc: arrival.id],
        preload: [:client]
    )
  end

  def route(arrival, attrs), do: route_many([arrival], attrs)

  def route_many([%Arrival{} | _] = arrivals, attrs) do
    org_id = hd(arrivals).org_id
    ids = Enum.map(arrivals, & &1.id)
    client_id = attrs[:client_id] || attrs["client_id"]
    period = attrs[:period] || attrs["period"]
    kind = attrs[:kind] || attrs["kind"]
    brought_in_by_id = attrs[:brought_in_by_id] || attrs["brought_in_by_id"]

    result =
      Repo.transact(fn ->
        with {:ok, locked} <- lock_pending(org_id, ids),
             {:ok, client} <- Repo.fetch_by(Client, id: client_id, org_id: org_id),
             true <- kind in Dump.kinds() do
          with {:ok, dump} <-
                 Dumps.record(
                   %{org_id: org_id, client_id: client.id, brought_in_by_id: brought_in_by_id},
                   %{
                     period: period,
                     kind: kind,
                     source: hd(locked).source,
                     file_keys: Enum.map(locked, & &1.storage_key)
                   }
                 ),
               {:ok, _job} <- Oban.insert(DumpWorker.new(%{dump_id: dump.id})) do
            Enum.each(locked, fn arrival ->
              arrival
              |> Arrival.changeset(%{status: "routed"})
              |> Ecto.Changeset.put_change(:routed_dump_id, dump.id)
              |> Repo.update!()
            end)

            {:ok, dump}
          end
        else
          false -> {:error, :invalid_kind}
          error -> error
        end
      end)

    if match?({:ok, _}, result), do: broadcast(org_id)
    result
  end

  def dismiss_many([%Arrival{} | _] = arrivals) do
    org_id = hd(arrivals).org_id
    ids = Enum.map(arrivals, & &1.id)

    result =
      Repo.transact(fn ->
        with {:ok, locked} <- lock_pending(org_id, ids) do
          Enum.each(locked, fn arrival ->
            arrival
            |> Arrival.changeset(%{status: "dismissed"})
            |> Repo.update!()
          end)

          {:ok, locked}
        end
      end)

    if match?({:ok, _}, result), do: broadcast(org_id)
    result
  end

  def subscribe(org_id), do: Phoenix.PubSub.subscribe(Nila.PubSub, topic(org_id))

  defp lock_pending(org_id, ids) do
    arrivals =
      Repo.all(
        from arrival in Arrival,
          where: arrival.org_id == ^org_id and arrival.id in ^ids,
          lock: "FOR UPDATE"
      )

    if length(arrivals) == length(ids) and Enum.all?(arrivals, &(&1.status == "pending")) do
      {:ok, arrivals}
    else
      {:error, :not_pending}
    end
  end

  defp existing(_org_id, _source, nil), do: nil

  defp existing(org_id, source, source_ref),
    do: Repo.get_by(Arrival, org_id: org_id, source: source, source_ref: source_ref)

  defp storage_key(org_id, content_type) do
    "orgs/#{org_id}/arrivals/#{Ecto.UUID.generate()}/original#{extension(content_type)}"
  end

  defp extension("application/pdf"), do: ".pdf"
  defp extension("application/json"), do: ".json"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/png"), do: ".png"
  defp extension(_content_type), do: ".bin"

  defp safe_filename(filename) when filename in ["", "."], do: "attachment.bin"
  defp safe_filename(filename), do: filename

  defp broadcast(org_id),
    do: Phoenix.PubSub.broadcast(Nila.PubSub, topic(org_id), {:gst_arrivals_changed, org_id})

  defp topic(org_id), do: "gst-arrivals:#{org_id}"
end
