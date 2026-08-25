defmodule Nila.Gst.Sales.Imports do
  @moduledoc "Recent sales-import batches for the sales intake page."

  import Ecto.Query

  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Sales.TallyPacket
  alias Nila.Repo

  @recent_dump_limit 100
  @recent_import_limit 15

  def recent(org_id) when is_integer(org_id) do
    recent(org_id, nil)
  end

  def recent(org_id, client_id) when is_integer(org_id) do
    query =
      from d in Dump,
        where:
          d.org_id == ^org_id and d.kind == "sales" and
            d.status in ["extracted", "failed"],
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: @recent_dump_limit,
        preload: [:client]

    query = if client_id, do: where(query, [d], d.client_id == ^client_id), else: query

    dumps =
      Repo.all(query)

    groups = Enum.group_by(dumps, &import_key/1)

    dumps
    |> Enum.uniq_by(&import_key/1)
    |> Enum.take(@recent_import_limit)
    |> Enum.map(fn dump -> import_row(Map.fetch!(groups, import_key(dump))) end)
  end

  defp import_key(%Dump{id: id, meta: meta}) do
    Map.get(meta || %{}, "sales_import_ref") || "dump:#{id}"
  end

  defp import_row(dumps) do
    dumps = Enum.sort_by(dumps, & &1.id)
    first = hd(dumps)
    packet = TallyPacket.prepare(dumps)

    review_count =
      length(packet.excluded) + length(packet.failed_files) + length(packet.unread_pages)

    %{
      dom_id: "sales-import-#{TallyPacket.ref(dumps)}",
      batch_ref: TallyPacket.ref(dumps),
      client_id: first.client_id,
      client_name: first.client.name,
      imported_at: Enum.max_by(dumps, & &1.inserted_at).inserted_at,
      invoice_count: length(packet.invoices) + length(packet.excluded),
      ready_count: length(packet.invoices),
      review_count: review_count
    }
  end
end
