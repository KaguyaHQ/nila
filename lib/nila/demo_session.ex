defmodule Nila.DemoSession do
  @moduledoc "Preparation and guarded reset for the disposable June 2026 sales demo."
  import Ecto.Query

  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Dump, ExtractionAttempt}
  alias Nila.Gst.Sales.{Batch, Month}
  alias Nila.Gst.Sales.Invoice.Correction, as: InvoiceCorrection
  alias Nila.Gst.Sales.Invoice.Removal, as: InvoiceRemoval
  alias Nila.Gst.Sales.Review.Resolution
  alias Nila.Repo

  @name "BREEZE TECH - Demo"
  @gstin "33AEWPH4158J1Z3"
  @marker "nila-demo:breeze-2026-06"
  @period "2026-06"
  @active_jobs ~w(available scheduled executing retryable)

  def available?(
        %Nila.Accounts.Scope{user: %{id: user_id}, current_org: %{id: org_id}},
        %Client{org_id: org_id} = client
      ) do
    designated_client(client) == :ok and
      Repo.exists?(
        from u in Nila.Accounts.User,
          join: m in Nila.Orgs.Membership,
          on: m.user_id == u.id,
          where:
            u.id == ^user_id and u.active == true and
              u.email == "spare.me1180650@gmail.com" and m.org_id == ^org_id and m.role == "owner"
      )
  end

  def available?(_, _), do: false

  def reset_for_user(scope, client_id) do
    with %Nila.Accounts.Scope{current_org: %{id: org_id}} <- scope,
         {:ok, client} <- Repo.fetch_by(Client, org_id: org_id, id: client_id),
         true <- available?(scope, client) do
      reset(org_id, client.id, "RESET #{org_id}/#{client.id}/#{@period}")
    else
      _ -> {:error, :forbidden}
    end
  end

  def reset_error(:processing_not_finished),
    do: "Invoices are still processing. Wait for processing to finish, then reset."

  def reset_error({:backup_failed, _}),
    do: "The backup could not be saved. Nothing was cleared. Try again."

  def reset_error(:forbidden), do: "Reset is not available for this account or client."

  def reset_error(_),
    do: "This client contains work outside the disposable June demo. Nothing was cleared."

  def setup(org_id) do
    with {:ok, _org} <- Repo.fetch(Nila.Orgs.Org, org_id) do
      case Repo.get_by(Client, org_id: org_id, name: @name) do
        nil ->
          Nila.Clients.create_client(%{
            org_id: org_id,
            name: @name,
            type: "company",
            gstin: @gstin,
            chase_channel: "none",
            match_hints: [@marker]
          })

        client ->
          with :ok <- designated_client(client), do: {:ok, client}
      end
    end
  end

  def inspect_session(org_id, client_id) do
    with {:ok, client} <- Repo.fetch_by(Client, org_id: org_id, id: client_id),
         :ok <- designated_client(client) do
      rows = rows(client)
      {:ok, report(client, rows)}
    end
  end

  # The explicit token prevents a copied inspection command from becoming a reset.
  # It is an operator confirmation, not a replacement for user authorization.
  def reset(org_id, client_id, confirmation) do
    if confirmation != "RESET #{org_id}/#{client_id}/#{@period}" do
      {:error, :confirmation_mismatch}
    else
      Repo.transact(fn ->
        with {:ok, client} <-
               Repo.fetch_one(
                 from c in Client,
                   where: c.org_id == ^org_id and c.id == ^client_id,
                   lock: "FOR UPDATE"
               ),
             :ok <- designated_client(client),
             snapshot <- rows(client, true),
             :ok <- safe_to_reset(client, snapshot),
             {:ok, backup_key} <- backup(client, snapshot) do
          # Child rows first; the client, original files and evidence remain.
          for key <- [
                :jobs,
                :corrections,
                :removals,
                :resolutions,
                :attempts,
                :dumps,
                :batches,
                :months
              ] do
            for row <- Map.fetch!(snapshot, key), do: Repo.delete!(row)
          end

          {:ok,
           %{
             backup_key: backup_key,
             removed: counts(snapshot),
             client_id: client.id,
             period: @period
           }}
        end
      end)
    end
  end

  defp designated_client(client) do
    if client.name == @name and client.gstin == @gstin and
         client.match_hints == [@marker] and client.chase_channel == "none" and
         is_nil(client.phone) and is_nil(client.email) and is_nil(client.active_tally_company_id),
       do: :ok,
       else: {:error, :not_the_disposable_demo_client}
  end

  defp rows(client, lock? \\ false) do
    dumps =
      all(from(d in Dump, where: d.org_id == ^client.org_id and d.client_id == ^client.id), lock?)

    months =
      all(
        from(m in Month, where: m.org_id == ^client.org_id and m.client_id == ^client.id),
        lock?
      )

    batches =
      all(
        from(b in Batch, where: b.org_id == ^client.org_id and b.client_id == ^client.id),
        lock?
      )

    dump_ids = Enum.map(dumps, & &1.id)
    dump_id_strings = Enum.map(dump_ids, &to_string/1)
    month_ids = Enum.map(months, & &1.id)

    %{
      dumps: dumps,
      months: months,
      batches: batches,
      corrections:
        all(
          from(c in InvoiceCorrection,
            where: c.org_id == ^client.org_id and c.client_id == ^client.id
          ),
          lock?
        ),
      removals:
        all(
          from(r in InvoiceRemoval,
            where: r.org_id == ^client.org_id and r.client_id == ^client.id
          ),
          lock?
        ),
      resolutions: all(from(r in Resolution, where: r.sales_month_id in ^month_ids), lock?),
      attempts: all(from(a in ExtractionAttempt, where: a.gst_dump_id in ^dump_ids), lock?),
      jobs:
        all(
          from(j in Oban.Job, where: fragment("?->>'dump_id'", j.args) in ^dump_id_strings),
          lock?
        )
    }
  end

  defp all(query, true), do: Repo.all(lock(query, "FOR UPDATE"))
  defp all(query, false), do: Repo.all(query)

  defp safe_to_reset(client, rows) do
    month_ids = Enum.map(rows.months, & &1.id)
    batch_ids = Enum.map(rows.batches, & &1.id)

    cond do
      Enum.any?(
        rows.dumps,
        &(&1.kind != "sales" or &1.period != @period or not is_nil(&1.source))
      ) ->
        {:error, :contains_other_work}

      Enum.any?(
        rows.months,
        &(&1.period != @period or &1.state == "filed" or not is_nil(&1.filed_at) or
            not is_nil(&1.filed_gstr1) or not is_nil(&1.filing_arn))
      ) ->
        {:error, :contains_other_or_filed_month}

      Repo.exists?(from s in Nila.Gst.Filing.Signoff, where: s.sales_month_id in ^month_ids) ->
        {:error, :contains_signoff}

      Repo.exists?(from m in Nila.Gst.Purchase.Month, where: m.client_id == ^client.id) ->
        {:error, :contains_purchase_work}

      Enum.any?(rows.dumps, &(&1.status in ["received", "extracting"])) or
        Enum.any?(rows.attempts, &(&1.status == "running")) or
          Enum.any?(rows.jobs, &(&1.state in @active_jobs)) ->
        {:error, :processing_not_finished}

      Enum.any?(rows.batches, &(not is_nil(&1.tally_company_id))) or
          Repo.exists?(from j in Nila.TallyJobs.Job, where: j.sales_batch_id in ^batch_ids) ->
        {:error, :contains_tally_handoff}

      true ->
        :ok
    end
  end

  defp report(client, rows) do
    %{
      org_id: client.org_id,
      client_id: client.id,
      name: client.name,
      gstin: client.gstin,
      period: @period,
      counts: counts(rows),
      reset_check: safe_to_reset(client, rows),
      start_path: "/gst/#{client.id}/#{@period}/sales",
      upload_path: "/gst/upload?client_id=#{client.id}&period=#{@period}&kind=sales",
      confirmation: "RESET #{client.org_id}/#{client.id}/#{@period}"
    }
  end

  defp counts(rows), do: Map.new(rows, fn {key, value} -> {key, length(value)} end)

  defp backup(client, rows) do
    if Enum.all?(rows, fn {_key, value} -> value == [] end) do
      {:ok, nil}
    else
      key = "orgs/#{client.org_id}/demo-backups/#{client.id}/#{Ecto.UUID.generate()}.etf"

      bytes =
        :erlang.term_to_binary(
          %{
            version: 1,
            client: client,
            period: @period,
            saved_at: DateTime.utc_now(),
            rows: rows
          },
          [:compressed]
        )

      with {:ok, _} <- Nila.Storage.put(key, bytes, content_type: "application/octet-stream"),
           {:ok, ^bytes} <- Nila.Storage.get(key) do
        {:ok, key}
      else
        error -> {:error, {:backup_failed, error}}
      end
    end
  end
end
