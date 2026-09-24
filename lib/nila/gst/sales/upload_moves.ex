defmodule Nila.Gst.Sales.UploadMoves do
  @moduledoc "Corrects an upload's client assignment without rereading its documents."
  import Ecto.Query
  alias Nila.{Clients, Repo, Storage, Gstin}
  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Sales.{Batch, Derivation, Invoice, Month, Months, Review, Workings}
  alias Nila.Gst.Sales.Invoice.{Correction, Removal}
  alias Nila.Gst.Sales.Review.{Resolution, Resolutions}

  def preview(scope, client_id, period, ref) do
    with :ok <- authorize(scope),
         {:ok, batch, dumps} <- full_batch(scope.current_org.id, client_id, period, ref),
         {:ok, seller} <- seller(dumps),
         :ok <- movable(batch, dumps) do
      {:ok,
       %{
         batch_ref: Batch.ref(dumps),
         period: period,
         invoice_count: Enum.sum(Enum.map(dumps, &length(&1.invoices))),
         files: Enum.map(dumps, &Nila.Gst.Sales.SourcePacket.original_name/1),
         seller: seller,
         clients:
           Clients.list_clients(scope.current_org.id)
           |> Enum.reject(&(&1.id == client_id))
           |> Enum.map(&Map.take(&1, [:id, :name, :gstin])),
         basis: basis(dumps)
       }}
    end
  end

  def move(scope, client_id, period, ref, destination_id, expected_basis) do
    with :ok <- authorize(scope),
         {:ok, _, initial} <- full_batch(scope.current_org.id, client_id, period, ref),
         {:ok, destination} <- Clients.get_client(scope.current_org.id, destination_id),
         true <- destination.id != client_id || {:error, :same_client} do
      Repo.transact(fn ->
        org_id = scope.current_org.id

        destination =
          Repo.one!(
            from c in Nila.Clients.Client,
              where: c.id == ^destination.id and c.org_id == ^org_id,
              lock: "FOR SHARE"
          )

        # Match source edits and filing: month rows before batch and dump rows.
        for id <- Enum.sort([client_id, destination.id]) do
          Repo.insert!(%Month{org_id: org_id, client_id: id, period: period, state: "collecting"},
            on_conflict: :nothing,
            conflict_target: [:client_id, :period]
          )
        end

        months =
          Repo.all(
            from m in Month,
              where: m.org_id == ^org_id and m.client_id in ^[client_id, destination.id],
              order_by: m.id,
              lock: "FOR UPDATE"
          )

        Repo.one!(from b in Batch, where: b.id == ^hd(initial).sales_batch_id, lock: "FOR UPDATE")

        Repo.all(
          from d in Dump,
            where: d.sales_batch_id == ^hd(initial).sales_batch_id,
            order_by: d.id,
            lock: "FOR UPDATE"
        )

        with {:ok, batch, dumps} <- full_batch(org_id, client_id, period, ref),
             :ok <- movable(batch, dumps),
             {:ok, seller} <- seller(dumps),
             true <- seller.gstin == destination.gstin || {:error, :wrong_seller},
             true <- basis(dumps) == expected_basis || {:error, :stale},
             :ok <- writable_months(months, dumps, period),
             :ok <- copy_evidence(dumps, destination.id) do
          source_ids = for dump <- dumps, invoice <- dump.invoices, do: Invoice.source_id(invoice)
          source_month = Enum.find(months, &(&1.client_id == client_id and &1.period == period))

          target_month =
            Enum.find(months, &(&1.client_id == destination.id and &1.period == period))

          legacy = legacy_edits(source_month, source_ids)

          for month <- [source_month, target_month],
              do: reopen_decisions(month, source_ids, scope.user.id)

          transfer_legacy_edits(legacy, target_month)

          # Corrections and exclusions follow stable source IDs; original attribution stays intact.
          Repo.update_all(
            from(c in Correction,
              where:
                c.org_id == ^org_id and c.client_id == ^client_id and c.source_id in ^source_ids
            ),
            set: [client_id: destination.id]
          )

          Repo.update_all(
            from(r in Removal,
              where:
                r.org_id == ^org_id and r.client_id == ^client_id and r.source_id in ^source_ids
            ),
            set: [client_id: destination.id]
          )

          batch |> Ecto.Changeset.change(client_id: destination.id) |> Repo.update!()

          event = %{
            "from_client_id" => client_id,
            "to_client_id" => destination.id,
            "period" => period,
            "moved_by_id" => scope.user.id,
            "at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          for dump <- dumps do
            meta = Map.update(dump.meta || %{}, "client_moves", [event], &(&1 ++ [event]))
            invoices = Enum.map(dump.invoices, &rebind(&1, destination.gstin))

            dump
            |> Ecto.Changeset.change(client_id: destination.id, invoices: invoices, meta: meta)
            |> Repo.update!()
          end

          :ok = Derivation.refresh_in_transaction(%{hd(dumps) | brought_in_by_id: scope.user.id})

          :ok =
            Derivation.refresh_in_transaction(%{
              hd(dumps)
              | client_id: destination.id,
                brought_in_by_id: scope.user.id
            })

          first =
            dumps
            |> Enum.flat_map(& &1.invoices)
            |> then(&Nila.Gst.Sales.Invoice.Removals.active_sources(org_id, destination.id, &1))
            |> List.first()

          review_url =
            if first,
              do:
                "/gst/#{destination.id}/#{period}/sales/invoices/#{URI.encode(Invoice.source_id(first))}",
              else: "/gst/#{destination.id}/#{period}/sales/register"

          {:ok,
           %{
             client_id: destination.id,
             period: period,
             review_url: review_url,
             invoice_count: length(source_ids)
           }}
        end
      end)
    end
  end

  defp authorize(scope) do
    if Nila.Accounts.Policy.can?(scope, :edit_records), do: :ok, else: {:error, :read_only}
  end

  defp full_batch(org, client, period, ref) do
    with {:ok, batch, requested} <- Batch.fetch_with_record(org, client, ref) do
      dumps = Repo.all(from d in Dump, where: d.sales_batch_id == ^batch.id, order_by: d.id)

      if Batch.ref(dumps) == Batch.ref(Enum.sort_by(requested, & &1.id)) and
           Enum.all?(
             dumps,
             &(&1.org_id == org and &1.client_id == client and &1.period == period and
                 &1.kind == "sales")
           ), do: {:ok, batch, dumps}, else: {:error, :not_found}
    end
  end

  defp seller(dumps) do
    invoices = Enum.flat_map(dumps, & &1.invoices)
    gstins = Enum.map(invoices, &observed_gstin/1) |> Enum.uniq()

    case gstins do
      [gstin] when is_binary(gstin) ->
        if Gstin.valid?(gstin),
          do:
            {:ok, %{gstin: gstin, name: hd(invoices)["seller_name"] || "Seller on these bills"}},
          else: {:error, :mixed_sellers}

      _ ->
        {:error, :mixed_sellers}
    end
  end

  defp observed_gstin(invoice) do
    value =
      case invoice["seller_identity"] do
        %{} = identity ->
          observed = identity["observed_gstin"]
          if Gstin.valid_extracted?(observed), do: observed, else: identity["source_gstin"]

        _ ->
          invoice["seller_gstin"]
      end

    if is_binary(value), do: value |> String.trim() |> String.upcase(), else: nil
  end

  defp rebind(invoice, gstin) do
    identity =
      Map.merge(
        invoice["seller_identity"] || %{"observed_gstin" => observed_gstin(invoice)},
        %{"client_gstin" => gstin, "status" => "matched"}
      )

    invoice |> Map.put("seller_gstin", gstin) |> Map.put("seller_identity", identity)
  end

  defp movable(batch, dumps) do
    ids = Enum.map(dumps, & &1.id)

    active_job =
      Repo.exists?(
        from j in Oban.Job,
          where: j.state in ["available", "scheduled", "executing", "retryable"],
          where: fragment("?->>'dump_id'", j.args) in ^Enum.map(ids, &to_string/1)
      )

    cond do
      batch.tally_company_id != nil or
          Repo.exists?(from j in Nila.TallyJobs.Job, where: j.sales_batch_id == ^batch.id) ->
        {:error, :posted}

      active_job or Enum.any?(dumps, &(&1.status != "extracted")) ->
        {:error, :processing}

      true ->
        :ok
    end
  end

  defp writable_months(months, dumps, period) do
    ids = for d <- dumps, i <- d.invoices, do: Invoice.source_id(i)

    cond do
      Enum.any?(months, &(&1.period == period and (&1.filed_at != nil or &1.state == "filed"))) ->
        {:error, :filed}

      Enum.any?(months, fn m ->
        m.period != period and Enum.any?(m.invoices, &(Invoice.source_id(&1) in ids))
      end) ->
        {:error, :other_month}

      true ->
        :ok
    end
  end

  defp basis(dumps) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        Enum.map(dumps, &{&1.id, &1.client_id, &1.period, &1.status, &1.invoices, &1.updated_at})
      )
    )
    |> Base.url_encode64(padding: false)
  end

  defp copy_evidence(dumps, destination_id) do
    Enum.reduce_while(dumps, :ok, fn dump, :ok ->
      names =
        for invoice <- dump.invoices,
            image <- List.wrap(invoice["images"] || invoice["image"]),
            is_binary(image),
            do: Path.basename(image)

      result =
        Enum.reduce_while(Enum.uniq(names), :ok, fn name, :ok ->
          with {:ok, bytes} <-
                 Storage.get(Months.evidence_key(dump.org_id, dump.client_id, dump.period, name)),
               {:ok, _} <-
                 Storage.put(
                   Months.evidence_key(dump.org_id, destination_id, dump.period, name),
                   bytes
                 ) do
            {:cont, :ok}
          else
            _ -> {:halt, {:error, :evidence_unavailable}}
          end
        end)

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp legacy_edits(source, ids) do
    source.id
    |> Resolutions.list()
    |> Enum.map(fn r ->
      %{
        "verb" => r.verb,
        "target" => r.target,
        "payload" => r.payload,
        "actor" => r.decided_by_id
      }
    end)
    |> Nila.Gst.Replay.drop_reopened("target")
    |> Enum.filter(&(&1["verb"] == "correct_field" and &1["target"] in ids))
  end

  defp transfer_legacy_edits(edits, destination) do
    for r <- edits do
      %Resolution{
        org_id: destination.org_id,
        sales_month_id: destination.id,
        decided_by_id: r["actor"]
      }
      |> Resolution.changeset(%{verb: r["verb"], target: r["target"], payload: r["payload"]})
      |> Repo.insert!()
    end
  end

  defp reopen_decisions(month, ids, user_id) do
    workings = Resolutions.workings(month)

    invoice_targets =
      Review.build(workings).all
      |> Enum.filter(&(&1.source_id in ids))
      |> Enum.flat_map(& &1.actionable_issues)
      |> Enum.map(&Workings.issue_key/1)

    month_targets =
      workings.issues
      |> Enum.filter(&(is_nil(&1["invoice"]) and is_nil(&1["source_id"])))
      |> Enum.map(&Workings.issue_key/1)

    targets = invoice_targets ++ month_targets

    for {_key, r} <- Resolutions.latest_decisions(month.id),
        r.verb != "reopen",
        r.target in targets or
          Enum.any?(ids, &(r.target == &1 or String.starts_with?(r.target, &1 <> ":"))) do
      %Resolution{org_id: month.org_id, sales_month_id: month.id, decided_by_id: user_id}
      |> Resolution.changeset(%{
        verb: "reopen",
        target: r.target,
        payload: %{"reason" => "upload_moved"}
      })
      |> Repo.insert!()
    end
  end
end
