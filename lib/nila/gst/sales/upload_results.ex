defmodule Nila.Gst.Sales.UploadResults do
  @moduledoc "Progress and saved invoice results for one sales upload."
  import Ecto.Query
  alias Nila.Repo
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias Nila.Gst.Sales.{Batch, Invoice, Processing, SourcePacket, Month}

  def load(org_id, client_id, period, ref) do
    with {:ok, dumps} <- fetch(org_id, client_id, period, ref) do
      {:ok,
       %{
         id: Batch.ref(dumps),
         processing: Enum.any?(dumps, &(&1.status in ~w(received extracting))),
         files: Enum.map(dumps, &file(&1, client_id, period))
       }}
    end
  end

  def retry(scope, client_id, period, ref, dump_id) when is_integer(dump_id) do
    if Nila.Accounts.Policy.can?(scope, :edit_records) do
      Repo.transact(fn ->
        org_id = scope.current_org.id

        months =
          Repo.all(
            from m in Month,
              where: m.org_id == ^org_id and m.client_id == ^client_id,
              order_by: m.id,
              lock: "FOR UPDATE"
          )

        with {:ok, dumps} <- fetch(org_id, client_id, period, ref),
             true <- Enum.any?(dumps, &(&1.id == dump_id)) || {:error, :not_found},
             dump <- Repo.one!(from d in Dump, where: d.id == ^dump_id, lock: "FOR UPDATE"),
             true <- dump.client_id == client_id || {:error, :not_found},
             false <-
               Enum.any?(
                 months,
                 fn month ->
                   affected =
                     month.period == period or
                       Enum.any?(month.invoices, fn invoice ->
                         Enum.any?(
                           dump.invoices,
                           &(Invoice.source_id(&1) == Invoice.source_id(invoice))
                         )
                       end)

                   affected and (month.filed_at != nil or month.state == "filed")
                 end
               ) do
          active =
            Repo.exists?(
              from j in Oban.Job,
                where: j.state in ["available", "scheduled", "executing", "retryable"],
                where: fragment("?->>'dump_id'", j.args) == ^to_string(dump_id)
            )

          cond do
            active or dump.status in ~w(received extracting) ->
              {:ok, %{ok: true}}

            dump.status != "failed" ->
              {:error, :processing}

            true ->
              with {:ok, _} <- Dumps.retry_failed(dump),
                   {:ok, _} <- Oban.insert(DumpWorker.new(%{dump_id: dump.id})),
                   do: {:ok, %{ok: true}}
          end
        else
          true -> {:error, :filed}
          error -> error
        end
      end)
    else
      {:error, :read_only}
    end
  end

  def retry(_, _, _, _, _), do: {:error, :invalid}

  def include_document(scope, client_id, period, ref, dump_id, pages, reason)
      when is_integer(dump_id) and is_list(pages) and is_binary(reason) do
    if Nila.Accounts.Policy.can?(scope, :edit_records) do
      Repo.transact(fn ->
        org_id = scope.current_org.id

        months =
          Repo.all(
            from m in Month,
              where: m.org_id == ^org_id and m.client_id == ^client_id,
              order_by: m.id,
              lock: "FOR UPDATE"
          )

        with {:ok, dumps} <- fetch(org_id, client_id, period, ref),
             true <- Enum.any?(dumps, &(&1.id == dump_id)) || {:error, :not_found},
             dump <- Repo.one!(from d in Dump, where: d.id == ^dump_id, lock: "FOR UPDATE"),
             true <-
               (dump.org_id == org_id and dump.client_id == client_id and dump.period == period) ||
                 {:error, :not_found},
             false <-
               Enum.any?(months, fn month ->
                 affected =
                   month.period == period or
                     Enum.any?(month.invoices, fn invoice ->
                       Enum.any?(
                         dump.invoices,
                         &(Invoice.source_id(&1) == Invoice.source_id(invoice))
                       )
                     end)

                 affected and (month.filed_at != nil or month.state == "filed")
               end),
             true <- dump.status == "extracted" || {:error, :processing},
             true <-
               (String.trim(reason) != "" and byte_size(reason) <= 2000) || {:error, :invalid},
             snapshot <- Processing.snapshot(dump),
             segments <- snapshot["segments"] || [],
             segment when not is_nil(segment) <-
               Enum.find(segments, &(&1["kind"] != "invoice" and &1["pages"] == pages)),
             true <-
               Enum.all?(
                 Enum.with_index(Enum.filter(segments, &(&1["kind"] == "invoice")), 1),
                 fn {segment, ordinal} ->
                   artifact = (snapshot["artifacts"] || %{})[to_string(ordinal)]
                   is_map(artifact) and artifact["source_pages"] == segment["pages"]
                 end
               ) || {:error, :evidence_unavailable} do
          included =
            segment |> Map.put("kind", "invoice") |> Map.put("document_type", "tax_invoice")

          snapshot =
            Map.put(snapshot, "segments", Enum.reject(segments, &(&1 == segment)) ++ [included])

          override = %{
            "pages" => pages,
            "original_classification" => segment,
            "reason" => String.trim(reason),
            "user_id" => scope.user.id,
            "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          meta =
            dump.meta
            |> Map.put("processing", snapshot)
            |> Map.update("document_overrides", [override], &(&1 ++ [override]))

          dump |> Dump.changeset(%{status: "received", meta: meta, error: nil}) |> Repo.update!()
          Oban.insert!(DumpWorker.new(%{dump_id: dump.id}))
          {:ok, %{ok: true}}
        else
          true -> {:error, :filed}
          nil -> {:error, :stale}
          error -> error
        end
      end)
    else
      {:error, :read_only}
    end
  end

  def include_document(_, _, _, _, _, _, _), do: {:error, :invalid}

  defp fetch(org, client, period, ref) do
    with {:ok, dumps} <- Batch.fetch(org, client, ref),
         true <-
           Enum.all?(dumps, &(&1.kind == "sales" and &1.period == period)) || {:error, :not_found},
         do: {:ok, dumps}
  end

  defp file(dump, client, period) do
    snapshot = Processing.snapshot(dump)
    segments = Enum.filter(snapshot["segments"] || [], &(&1["kind"] == "invoice"))

    {active, removed} =
      Nila.Gst.Sales.Invoice.Removals.partition_removed(dump.org_id, client, dump.invoices)

    removed_ids = MapSet.new(removed, &Invoice.source_id/1)
    saved = Map.new(dump.invoices, &{Invoice.source_id(&1), &1})

    rows =
      if segments == [] do
        Enum.map(dump.invoices, &row(&1, nil, nil, dump, client, period, removed_ids))
      else
        segments
        |> Enum.with_index(1)
        |> Enum.map(fn {segment, ordinal} ->
          row(
            saved[Processing.source_id(dump, ordinal)],
            segment,
            ordinal,
            dump,
            client,
            period,
            removed_ids
          )
        end)
      end

    %{
      id: dump.id,
      name: SourcePacket.original_name(dump),
      state: dump.status,
      completed: length(dump.invoices),
      total: if(segments == [], do: nil, else: length(segments)),
      reviewable: length(active),
      skipped_documents:
        (snapshot["segments"] || [])
        |> Enum.reject(&(&1["kind"] == "invoice"))
        |> Enum.map(fn segment ->
          %{
            pages: segment["pages"] || [],
            document_type: segment["document_type"],
            reason: segment["reason"]
          }
        end),
      rows: rows,
      original_url:
        if(dump.file_keys != [], do: "/gst/#{client}/#{period}/original/#{dump.id}/0"),
      message: message(dump)
    }
  end

  defp row(invoice, segment, ordinal, dump, client, period, removed) do
    id = if invoice, do: Invoice.source_id(invoice), else: Processing.source_id(dump, ordinal)

    state =
      cond do
        MapSet.member?(removed, id) ->
          "removed"

        invoice != nil ->
          "ready"

        dump.status == "failed" or ordinal in (Processing.snapshot(dump)["failed"] || []) ->
          "failed"

        true ->
          "reading"
      end

    %{
      id: id,
      number: if(invoice, do: invoice["invoice_number"], else: segment["invoice_no"]),
      buyer: if(invoice, do: invoice["buyer_name"]),
      state: state,
      pages: if(invoice, do: invoice["source_pages"] || [], else: segment["pages"] || []),
      review_url:
        if(state == "ready" and Processing.reviewable?(dump),
          do: "/gst/#{client}/#{period}/sales/invoices/#{URI.encode(id)}"
        )
    }
  end

  defp message(%{status: "failed", invoices: []}),
    do: "Reading failed. Try again without uploading the PDF again."

  defp message(%{status: "failed"}),
    do: "Reading stopped. Completed invoices are saved; retry resumes the remaining read."

  defp message(%{status: status}) when status in ~w(received extracting),
    do: "You can review completed invoices while the rest are being read."

  defp message(%{status: "extracted"} = dump) do
    if (dump.meta || %{})["unaccounted_pages"] in [nil, []] do
      "Reading finished. Review the invoices before using the working."
    else
      "Some PDF pages were not included as invoices. Check the skipped documents against the source PDF."
    end
  end

  defp message(_), do: "This upload needs attention before its invoices can enter the working."
end
