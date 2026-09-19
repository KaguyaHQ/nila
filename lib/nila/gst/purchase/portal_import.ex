defmodule Nila.Gst.Purchase.PortalImport do
  @moduledoc "Snapshots a saved portal statement into the purchase reconciliation intake."
  import Ecto.Query
  alias Nila.{Clients, Repo, Storage}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias Nila.Gst.Portal.Gstr2b
  alias Nila.Gst.Purchase.Month

  @doc "The latest intake of this saved statement, if its contents still match."
  def current_dump(nil, _dumps), do: nil

  def current_dump(statement, dumps) do
    latest =
      dumps |> Enum.filter(&(&1.kind == "gstr2b" and &1.status != "discarded")) |> List.last()

    if latest && latest.meta["portal_document_sha256"] == document_digest(statement.document),
      do: latest
  end

  defp document_digest(document),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(document, [:deterministic]))
      |> Base.encode16(case: :lower)

  def import(scope, client_id, period) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, _} <- Gstr2b.month(period),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id) do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [73_014, client.id])

        Repo.one(
          from m in Month,
            where:
              m.org_id == ^scope.current_org.id and m.client_id == ^client.id and
                m.period == ^period,
            lock: "FOR UPDATE"
        )

        probe = %Dump{
          org_id: scope.current_org.id,
          client_id: client.id,
          period: period,
          kind: "gstr2b"
        }

        with :open <- DumpWorker.wall_state(probe),
             %{document: document, fetched_at: fetched_at} = statement
             when is_map(document) and not is_nil(fetched_at) <-
               Gstr2b.saved(scope.current_org.id, client.id, period),
             :ok <- identity(document, client.gstin, period),
             :ok <- supported(document),
             {:ok, _} <- Nila.Gst.Filing.Gstr2b.parse(document) do
          save(scope, client, period, statement)
        else
          :held ->
            {:error,
             "This purchase month is signed off. Reopen it before importing another statement."}

          :after_filing ->
            {:error, "This purchase month is filed. Its statement cannot be replaced."}

          nil ->
            {:error, "Fetch GSTR-2B for this client and month first."}

          {:error, _} = error ->
            error

          _ ->
            {:error, "No complete GSTR-2B statement is saved for this month."}
        end
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp identity(%{"data" => %{"gstin" => gstin, "rtnprd" => return_period}}, gstin, period) do
    {:ok, date} = Gstr2b.month(period)

    if return_period == Calendar.strftime(date, "%m%Y"),
      do: :ok,
      else: {:error, "The saved statement belongs to a different return month."}
  end

  defp identity(_, _, _), do: {:error, "The saved statement does not match this client's GSTIN."}

  defp supported(%{"data" => %{"docdata" => sections}}) when is_map(sections) do
    unsupported =
      sections
      |> Enum.reject(fn {key, value} -> key in ~w(b2b cdnr) or value in [nil, [], %{}] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if unsupported == [],
      do: :ok,
      else:
        {:error,
         "This statement contains unsupported sections: #{Enum.join(unsupported, ", ")}. Nothing was imported."}
  end

  defp supported(_), do: {:error, "The saved statement has an unsupported structure."}

  defp save(scope, client, period, statement) do
    # Hash the map deterministically rather than depending on JSON key order.
    digest = document_digest(statement.document)

    existing =
      Dumps.list(scope.current_org.id, client.id, period)
      |> Enum.filter(&(&1.kind == "gstr2b" and &1.status != "discarded"))
      |> List.last()

    if existing && existing.meta["portal_document_sha256"] == digest do
      retry_if_failed(existing)
    else
      key =
        "orgs/#{scope.current_org.id}/clients/#{client.id}/#{period}/gstr2b/#{Ecto.UUID.generate()}.json"

      with {:ok, _} <- Storage.put(key, Jason.encode!(statement.document)),
           {:ok, dump} <-
             Dumps.record(
               %{
                 org_id: scope.current_org.id,
                 client_id: client.id,
                 brought_in_by_id: scope.user.id
               },
               %{
                 period: period,
                 kind: "gstr2b",
                 file_keys: [key],
                 meta: %{
                   "original_name" => "GSTR-2B-#{period}.json",
                   "portal_statement_id" => statement.id,
                   "portal_fetched_at" => DateTime.to_iso8601(statement.fetched_at),
                   "portal_document_sha256" => digest
                 }
               }
             ) do
        %{dump_id: dump.id} |> DumpWorker.new() |> Oban.insert!()
        {:ok, dump}
      end
    end
  end

  defp retry_if_failed(%Dump{status: "failed"} = dump) do
    with {:ok, dump} <- Dumps.retry_failed(dump) do
      active_job? =
        Repo.exists?(
          from j in Oban.Job,
            where:
              j.worker == "Nila.Gst.Intake.DumpWorker" and
                fragment("? @> ?", j.args, ^%{"dump_id" => dump.id}) and
                j.state in ["available", "scheduled", "executing", "retryable", "suspended"]
        )

      unless active_job?, do: %{dump_id: dump.id} |> DumpWorker.new() |> Oban.insert!()
      {:ok, dump}
    end
  end

  defp retry_if_failed(dump), do: {:ok, dump}
end
