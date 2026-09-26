defmodule Nila.Demo do
  @moduledoc "Reset a designated demo firm, keeping its identity and memberships."
  import Ecto.Query

  alias Nila.Accounts.Scope
  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  # Child records with restrictive foreign keys must go before their parents.
  # Remaining client-owned records are removed by database cascades.
  @org_tables ~w(
    gst_itc_allocations gst_itc_source_case_events gst_itc_case_events gst_itc_cases
    gst_arrivals gst_intake_messages gst_intake_confirmations gst_extraction_attempts
    gst_resolutions gst_signoffs sales_resolutions sales_invoice_corrections sales_invoice_removals
    bank_transactions bank_statements tally_jobs gst_dumps gst_itc_sources client_months
    sales_months gst_sales_batches gst_chase_asks notice_check_runs
    tally_synced_masters tally_synced_vouchers tally_party_mappings tally_posting_profiles
    tally_sales_line_mappings tally_sync_runs tally_device_pairings tally_devices tally_companies
    integration_connections clients
  )
  @business_tables ~w(business_invoices business_invoice_counters business_customers business_services business_profiles)

  # Operator-only designation: deliberately absent from the public org changeset.
  def designate(org_id) do
    with {:ok, org} <- Repo.fetch(Org, org_id) do
      org |> Ecto.Changeset.change(is_demo: true) |> Repo.update()
    end
  end

  def available?(%Scope{user: %{id: user_id}, current_org: %{id: org_id}}) do
    Repo.exists?(
      from m in Membership,
        join: u in assoc(m, :user),
        join: o in assoc(m, :org),
        where:
          m.user_id == ^user_id and m.org_id == ^org_id and m.role == "owner" and
            u.active and o.is_demo and o.status == "active"
    )
  end

  def available?(_), do: false

  def reset(%Scope{current_org: %{id: org_id}} = scope) do
    Repo.transact(fn ->
      # Serialize resets and prevent new client inserts until the reset commits.
      Repo.one!(from o in Org, where: o.id == ^org_id, lock: "FOR UPDATE")

      if available?(scope) do
        reset_firm(org_id)
      else
        {:error, :forbidden}
      end
    end)
  end

  def reset(_), do: {:error, :forbidden}

  def reset_error(:forbidden), do: "Reset is only available to an owner of a demo firm."
  def reset_error(:processing), do: "Work is still processing. Wait for it to finish, then reset."

  defp reset_firm(org_id) do
    clients =
      Repo.all(from c in "clients", where: c.org_id == ^org_id, select: c.id, lock: "FOR UPDATE")

    # Oban claims jobs using row locks. This short table lock makes the executing
    # check and deletion of queued jobs atomic with respect to new claims.
    Repo.query!("LOCK TABLE oban_jobs IN SHARE ROW EXCLUSIVE MODE")
    jobs = jobs(org_id, clients)

    if Enum.any?(jobs, &(&1.state == "executing")) do
      {:error, :processing}
    else
      job_ids = Enum.map(jobs, & &1.id)
      Repo.delete_all(from j in Oban.Job, where: j.id in ^job_ids)

      invoices = from i in "business_invoices", where: i.client_id in ^clients

      Repo.update_all(invoices,
        set: [revised_from_id: nil, original_invoice_id: nil, converted_invoice_id: nil]
      )

      for table <- @business_tables do
        Repo.delete_all(from row in table, where: field(row, :client_id) in ^clients)
      end

      for table <- @org_tables do
        Repo.delete_all(from row in table, where: field(row, :org_id) == ^org_id)
      end

      {:ok, %{clients_removed: length(clients)}}
    end
  end

  defp jobs(org_id, clients) do
    references = %{
      "org_id" => [org_id],
      "client_id" => clients,
      "dump_id" => ids("gst_dumps", org_id),
      "connection_id" => ids("integration_connections", org_id),
      "run_id" => ids("notice_check_runs", org_id)
    }

    query =
      Enum.reduce(references, dynamic(false), fn {key, ids}, acc ->
        values = Enum.map(ids, &to_string/1)
        dynamic([j], ^acc or fragment("? ->> ?", j.args, ^key) in ^values)
      end)

    statements = ids("bank_statements", org_id) |> Enum.map(&to_string/1)

    Repo.all(
      from j in Oban.Job,
        where: ^query,
        or_where:
          j.worker == "Nila.Banking.StatementWorker" and
            fragment("? ->> 'statement_id'", j.args) in ^statements
    )
  end

  defp ids(table, org_id),
    do: Repo.all(from r in table, where: field(r, :org_id) == ^org_id, select: r.id)
end
