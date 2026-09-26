defmodule Nila.Gst.Sales.Uploads do
  @moduledoc "PDF upload preparation, verified finalization, and sales source history."

  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Sales.{Batch, Invoice, SourcePacket}
  alias Nila.{Repo, Storage}

  @salt "sales PDF upload"
  @max_bytes 50_000_000

  def prepare(scope, client_id, period, files) do
    with :ok <- validate_files(files),
         {:ok, entries} <- presign(scope.current_org.id, files) do
      payload = %{
        org_id: scope.current_org.id,
        user_id: scope.user.id,
        client_id: client_id,
        period: period,
        import_ref: Ecto.UUID.generate(),
        files: Enum.map(entries, &Map.drop(&1, [:url]))
      }

      {:ok,
       %{
         token: Phoenix.Token.sign(NilaWeb.Endpoint, @salt, payload),
         files: Enum.map(entries, &Map.take(&1, [:name, :url]))
       }}
    end
  end

  def create(scope, client_id, period, token) when is_binary(token) do
    with {:ok, payload} <- verify(scope, client_id, period, token, :infinity) do
      case find_batch(payload) do
        {:ok, batch} ->
          committed(batch)

        {:error, :not_found} ->
          with {:ok, fresh} <- verify(scope, client_id, period, token) do
            finalize_new(fresh)
          end
      end
    end
  end

  def create(_scope, _client_id, _period, _token), do: {:error, :invalid_token}

  def refresh(scope, client_id, period, token) do
    with {:ok, payload} <- verify(scope, client_id, period, token) do
      Enum.reduce_while(payload.files, {:ok, []}, fn file, {:ok, files} ->
        case Storage.presign_put(file.key) do
          {:ok, url} -> {:cont, {:ok, files ++ [%{name: file.name, url: url}]}}
          {:error, _} -> {:halt, {:error, :storage_unavailable}}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, %{token: token, files: files}}
        error -> error
      end
    end
  end

  defp verify(scope, client_id, period, token, max_age \\ 3600)

  defp verify(scope, client_id, period, token, max_age) when is_binary(token) do
    with {:ok, payload} <- Phoenix.Token.verify(NilaWeb.Endpoint, @salt, token, max_age: max_age),
         true <-
           payload.org_id == scope.current_org.id and payload.user_id == scope.user.id and
             payload.client_id == client_id and payload.period == period do
      {:ok, payload}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp verify(_scope, _client_id, _period, _token, _max_age), do: {:error, :invalid_token}

  def history(org_id, client_id, period) do
    dumps = Dumps.list(org_id, client_id, period) |> Enum.filter(&(&1.kind == "sales"))

    batches =
      dumps
      |> Enum.group_by(&(&1.sales_batch_id || {:dump, &1.id}))
      |> Map.values()
      |> Enum.map(fn group ->
        group = Enum.sort_by(group, & &1.id)
        first = hd(group)
        invoices = Enum.flat_map(group, & &1.invoices)

        {active, removed} =
          Nila.Gst.Sales.Invoice.Removals.partition_removed(org_id, client_id, invoices)

        %{
          id: Batch.ref(group),
          active_invoice_ids: Enum.map(active, &Invoice.source_id/1),
          removed_invoices:
            Enum.map(
              removed,
              &%{id: Invoice.source_id(&1), number: &1["invoice_number"] || Invoice.source_id(&1)}
            ),
          created_at: first.inserted_at,
          files: Enum.flat_map(group, &file_rows(&1, client_id, period)),
          invoice_ids:
            Enum.flat_map(group, fn dump ->
              Enum.map(dump.invoices || [], &Invoice.source_id/1)
            end),
          review_url: "/sales-bills/#{client_id}/batch/#{Batch.ref(group)}"
        }
      end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    %{batches: batches, processing: Enum.any?(dumps, &(&1.status in ~w(received extracting)))}
  end

  defp validate_files(files) when is_list(files) and length(files) in 1..50 do
    if Enum.all?(files, &valid_file?/1), do: :ok, else: {:error, :invalid_files}
  end

  defp validate_files(_), do: {:error, :invalid_files}

  defp valid_file?(%{"name" => name, "size" => size})
       when is_binary(name) and is_integer(size) and size > 0 and size <= @max_bytes do
    String.valid?(name) and byte_size(name) <= 255 and
      not String.contains?(name, ["/", "\\", <<0>>]) and
      String.downcase(Path.extname(name)) == ".pdf"
  end

  defp valid_file?(_), do: false

  defp presign(org_id, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, entries} ->
      key = "orgs/#{org_id}/dumps/#{Ecto.UUID.generate()}/pending.pdf"

      case Storage.presign_put(key) do
        {:ok, url} ->
          entry = %{key: key, url: url, name: file["name"], size: file["size"]}
          {:cont, {:ok, entries ++ [entry]}}

        {:error, _} ->
          {:halt, {:error, :storage_unavailable}}
      end
    end)
  end

  defp finalize_new(payload) do
    with {:ok, files} <- freeze_files(payload) do
      result =
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            payload.import_ref
          ])

          case find_batch(payload) do
            {:ok, _batch} -> {:ok, :existing}
            {:error, :not_found} -> record_batch(payload, files)
          end
        end)

      # A racing request may have committed while these files were being copied.
      # Its originals remain authoritative; remove only our unused copies.
      if result != {:ok, :created}, do: Enum.each(files, &Storage.delete(&1.original_key))

      case result do
        {:ok, _} ->
          Enum.each(payload.files, &Storage.delete(&1.key))
          committed_payload(payload)

        error ->
          error
      end
    else
      {:error, reason} ->
        case find_batch(payload) do
          {:ok, batch} -> committed(batch)
          {:error, :not_found} -> {:error, reason}
        end
    end
  end

  defp committed_payload(payload) do
    with {:ok, batch} <- find_batch(payload), do: committed(batch)
  end

  defp committed(batch) do
    import Ecto.Query

    dumps =
      Repo.all(
        from d in Nila.Gst.Intake.Dump, where: d.sales_batch_id == ^batch.id, order_by: d.id
      )

    {:ok, %{ok: true, batch_ref: Batch.ref(dumps)}}
  end

  # The upload token remains idempotent after its batch moves to another client.
  defp find_batch(payload),
    do:
      Repo.fetch_by(Batch,
        org_id: payload.org_id,
        import_ref: payload.import_ref
      )

  defp freeze_files(payload) do
    Enum.reduce_while(payload.files, {:ok, []}, fn file, {:ok, saved} ->
      # PUT URLs remain writable until expiry. Workers receive separate originals.
      key = "orgs/#{payload.org_id}/dumps/#{Ecto.UUID.generate()}/original.pdf"

      result =
        with {:ok, bytes} <- read_pdf(file),
             {:ok, _} <- Storage.put(key, bytes, content_type: "application/pdf"),
             do: {:ok, Map.put(file, :original_key, key)}

      case result do
        {:ok, original} ->
          {:cont, {:ok, saved ++ [original]}}

        {:error, reason} ->
          Enum.each(saved, &Storage.delete(&1.original_key))
          {:halt, {:error, reason}}
      end
    end)
  end

  defp record_batch(payload, files) do
    with {:ok, batch} <- Batch.create(payload.org_id, payload.client_id, payload.import_ref),
         :ok <- record_files(payload, batch.id, files) do
      {:ok, :created}
    end
  end

  defp record_files(payload, batch_id, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case record_file(payload, batch_id, file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_file(payload, batch_id, file) do
    with {:ok, dump} <-
           Dumps.record(
             %{
               org_id: payload.org_id,
               client_id: payload.client_id,
               brought_in_by_id: payload.user_id,
               sales_batch_id: batch_id
             },
             %{
               period: payload.period,
               kind: "sales",
               file_keys: [file.original_key],
               meta: %{
                 "sales_batch" => true,
                 "sales_import_ref" => payload.import_ref,
                 "original_name" => file.name
               }
             }
           ),
         {:ok, _} <- Oban.insert(DumpWorker.new(%{dump_id: dump.id})) do
      :ok
    end
  end

  defp read_pdf(file) do
    case Storage.get(file.key) do
      {:ok, <<"%PDF-", _::binary>> = bytes} when byte_size(bytes) == file.size -> {:ok, bytes}
      {:ok, _} -> {:error, :invalid_pdf}
      {:error, :enoent} -> {:error, :invalid_pdf}
      {:error, _} -> {:error, :storage_unavailable}
    end
  end

  defp file_rows(%{file_keys: keys, meta: meta} = dump, client_id, period) do
    manifest = (meta || %{})["file_manifest"]

    if is_list(manifest) and length(manifest) == length(keys) and keys != [] do
      manifest
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        file_row(
          dump,
          client_id,
          period,
          index,
          entry["filename"] || SourcePacket.original_name(dump)
        )
      end)
    else
      [file_row(dump, client_id, period, 0, SourcePacket.original_name(dump))]
    end
  end

  defp file_row(dump, client_id, period, index, name) do
    %{
      id: dump.id,
      name: name,
      state: dump.status,
      label:
        if((dump.meta || %{})["excel_import"] and dump.status == "extracted",
          do: "Imported",
          else: label(dump)
        ),
      invoice_count: if((dump.meta || %{})["excel_import"], do: 0, else: length(dump.invoices)),
      error:
        if(dump.status == "failed",
          do:
            if(dump.invoices == [],
              do: "Reading failed. Open this upload to try again.",
              else:
                "Reading stopped. Completed invoices are saved. Open this upload to retry the remaining read."
            )
        ),
      original_url:
        if(dump.file_keys != [], do: "/gst/#{client_id}/#{period}/original/#{dump.id}/#{index}")
    }
  end

  defp label(%{status: "extracted", meta: meta}) do
    if (meta || %{})["unaccounted_pages"] in [nil, []], do: "Read", else: "Partly read"
  end

  defp label(%{status: "received"}), do: "Queued"
  defp label(%{status: "extracting"}), do: "Reading bills"
  defp label(%{status: "failed", invoices: [_ | _]}), do: "Reading stopped"
  defp label(%{status: "failed"}), do: "Could not read"
  defp label(%{status: "held"}), do: "Held for review"
  defp label(%{status: "needs_confirmation"}), do: "Confirm the month"
  defp label(%{status: "after_filing"}), do: "Received after filing"
  defp label(%{status: "discarded"}), do: "Discarded"
end
