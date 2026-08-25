defmodule Nila.Banking do
  @moduledoc """
  Bank-statement intake: a native text PDF becomes a stored, tenant-scoped
  transaction artifact before it can be exported to Tally.
  """

  import Ecto.Query

  alias Nila.Banking.{Statement, Transaction}
  alias Nila.Repo
  alias Nila.TallyDevices.{Company, SyncedMaster}
  alias Nila.{TallyJobs, TallySync}
  alias Nila.Banking.Tally

  @banks [{"HDFC Bank", "hdfc"}, {"Kotak Mahindra Bank / 811", "kotak"}]

  def banks, do: @banks

  def bank_name(code) do
    Enum.find_value(@banks, fn {name, value} -> value == code && name end)
  end

  def record_statement(%{org_id: org_id, client_id: client_id} = scope, attrs) do
    %Statement{
      org_id: org_id,
      client_id: client_id,
      brought_in_by_id: scope[:brought_in_by_id]
    }
    |> Statement.create_changeset(attrs)
    |> Repo.insert()
  end

  def get_statement(org_id, id) do
    result =
      Repo.fetch_one(
        from statement in Statement,
          where: statement.org_id == ^org_id and statement.id == ^id,
          preload: [
            :client,
            :brought_in_by,
            tally_company: [:device],
            bank_transactions: [:tally_job]
          ]
      )

    case result do
      {:ok, statement} ->
        statement = ensure_transaction_rows(statement)
        {:ok, refresh_job_states(statement)}

      error ->
        error
    end
  end

  def recent_statements(org_id) when is_integer(org_id) do
    Repo.all(
      from statement in Statement,
        where: statement.org_id == ^org_id,
        order_by: [desc: statement.inserted_at, desc: statement.id],
        limit: 15,
        preload: [:client, bank_transactions: [:tally_job]]
    )
  end

  def mark_extracting(%Statement{} = statement) do
    statement
    |> Ecto.Changeset.change(status: "extracting", error: nil)
    |> Repo.update!()
  end

  def register_source_hash(%Statement{} = statement, bytes) when is_binary(bytes) do
    digest = :crypto.hash(:sha256, bytes)

    case statement |> Statement.source_hash_changeset(digest) |> Repo.update() do
      {:ok, statement} ->
        {:ok, statement}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :org_id),
          do: {:error, :duplicate_statement},
          else: {:error, :fingerprint_failed}
    end
  end

  def mark_ready(%Statement{} = statement, artifact) do
    attrs = %{
      status: "ready",
      source_credentials: nil,
      account_number_masked: artifact.account_number_masked,
      statement_from: artifact.statement_from,
      statement_to: artifact.statement_to,
      opening_balance_paise: artifact.opening_balance_paise,
      closing_balance_paise: artifact.closing_balance_paise,
      total_withdrawal_paise: artifact.total_withdrawal_paise,
      total_deposit_paise: artifact.total_deposit_paise,
      transaction_count: length(artifact.transactions),
      transactions: artifact.transactions,
      meta: artifact.meta,
      error: nil
    }

    Repo.transact(fn ->
      with {:ok, statement} <- statement |> Ecto.Changeset.change(attrs) |> Repo.update(),
           :ok <- replace_transactions(statement, artifact.transactions) do
        {:ok, statement}
      end
    end)
    |> case do
      {:ok, statement} ->
        statement

      {:error, reason} ->
        raise "could not persist bank statement transactions: #{inspect(reason)}"
    end
  end

  def list_transactions(org_id, statement_id) do
    from(transaction in Transaction,
      where: transaction.org_id == ^org_id and transaction.statement_id == ^statement_id,
      order_by: [asc: transaction.ordinal],
      preload: [:tally_job]
    )
    |> Repo.all()
  end

  def list_tally_ledgers(org_id, company_id) do
    Repo.all(
      from master in SyncedMaster,
        where:
          master.org_id == ^org_id and master.company_id == ^company_id and
            master.kind == "ledger",
        order_by: [asc: master.name]
    )
  end

  def list_tally_bank_ledgers(org_id, company_id) do
    Repo.all(
      from master in SyncedMaster,
        where:
          master.org_id == ^org_id and master.company_id == ^company_id and
            master.kind == "ledger" and
            fragment("lower(coalesce(?->>'parent', ''))", master.data) in [
              "bank accounts",
              "bank od a/c",
              "bank occ a/c"
            ],
        order_by: [asc: master.name]
    )
  end

  def configure_tally(org_id, statement_id, company_id, bank_ledger_identity) do
    Repo.transact(fn ->
      with {:ok, statement} <- get_statement(org_id, statement_id),
           :ok <- ensure_posting_not_started(statement.id),
           %Company{} = company <-
             Repo.one(
               from company in Company,
                 join: device in assoc(company, :device),
                 where:
                   company.id == ^company_id and company.org_id == ^org_id and
                     company.client_id == ^statement.client_id and company.is_open and
                     is_nil(device.revoked_at),
                 preload: [device: device]
             ) || {:error, :company_not_available},
           %SyncedMaster{} = ledger <- bank_ledger(org_id, company.id, bank_ledger_identity),
           {:ok, saved} <-
             statement
             |> Ecto.Changeset.change(
               tally_company_id: company.id,
               bank_ledger_identity: ledger.identity,
               bank_ledger_name: ledger.name
             )
             |> Repo.update() do
        if statement.tally_company_id && statement.tally_company_id != company.id do
          from(transaction in Transaction,
            where:
              transaction.statement_id == ^statement.id and
                transaction.status in ["unassigned", "ready", "failed"]
          )
          |> Repo.update_all(
            set: [
              counter_ledger_identity: nil,
              counter_ledger_name: nil,
              status: "unassigned",
              updated_at: DateTime.utc_now()
            ]
          )
        end

        {:ok, saved}
      else
        nil -> {:error, :ledger_not_found}
        error -> error
      end
    end)
  end

  def map_transactions(org_id, statement_id, transaction_ids, ledger_identity, type \\ nil)

  def map_transactions(org_id, statement_id, transaction_ids, ledger_identity, type)
      when is_list(transaction_ids) and transaction_ids != [] and length(transaction_ids) <= 1_000 do
    transaction_ids = Enum.uniq(transaction_ids)

    Repo.transact(fn ->
      with {:ok, statement} <- get_statement(org_id, statement_id),
           true <- is_integer(statement.tally_company_id) || {:error, :tally_not_configured},
           %SyncedMaster{} = ledger <- ledger(org_id, statement.tally_company_id, ledger_identity),
           :ok <- ensure_distinct_ledger(statement, ledger),
           transactions when length(transactions) == length(transaction_ids) <-
             editable_transactions(org_id, statement.id, transaction_ids) do
        Enum.reduce_while(transactions, {:ok, []}, fn transaction, {:ok, updated} ->
          attrs = %{
            counter_ledger_identity: ledger.identity,
            counter_ledger_name: ledger.name,
            transaction_type: type || transaction.transaction_type,
            status: "ready"
          }

          case transaction |> Transaction.mapping_changeset(attrs) |> Repo.update() do
            {:ok, saved} -> {:cont, {:ok, [saved | updated]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, updated} -> {:ok, Enum.reverse(updated)}
          error -> error
        end
      else
        false -> {:error, :transactions_changed}
        nil -> {:error, :ledger_not_found}
        error -> error
      end
    end)
  end

  def map_transactions(_org_id, _statement_id, _ids, _ledger, _type),
    do: {:error, :invalid_transactions}

  def enqueue_transactions(org_id, statement_id, transaction_ids)
      when is_list(transaction_ids) and transaction_ids != [] do
    with {:ok, statement} <- get_statement(org_id, statement_id),
         %Company{is_open: true, device: %{}} = company <- statement.tally_company,
         true <- is_binary(statement.bank_ledger_identity) || {:error, :tally_not_configured},
         transactions when transactions != [] <-
           ready_transactions(org_id, statement.id, transaction_ids),
         [] <-
           TallySync.missing_ledgers(
             company.id,
             [statement.bank_ledger_name | Enum.map(transactions, & &1.counter_ledger_name)]
           ) do
      Enum.reduce_while(transactions, {:ok, []}, fn transaction, {:ok, queued} ->
        with {:ok, xml} <-
               Tally.build_transaction(
                 statement,
                 transaction,
                 statement.bank_ledger_name,
                 transaction.counter_ledger_name
               ),
             {:ok, job, _disposition} <-
               TallyJobs.enqueue_import_vouchers(company, xml, 1,
                 source_key: "bank:#{statement.id}:transaction:#{transaction.identity}",
                 retry_failed: true,
                 metadata: %{
                   "source_id" => transaction.identity,
                   "bank_statement_id" => statement.id,
                   "bank_transaction_id" => transaction.id
                 }
               ),
             {:ok, transaction} <-
               transaction
               |> Ecto.Changeset.change(tally_job_id: job.id, status: job_status(job.status))
               |> Repo.update() do
          {:cont, {:ok, [transaction | queued]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, queued} -> {:ok, Enum.reverse(queued)}
        error -> error
      end
    else
      nil -> {:error, :tally_not_configured}
      [] -> {:error, :no_ready_transactions}
      missing when is_list(missing) -> {:error, {:missing_ledgers, missing}}
      error -> error
    end
  end

  def enqueue_transactions(_org_id, _statement_id, _transaction_ids),
    do: {:error, :invalid_transactions}

  def set_ignored(org_id, statement_id, transaction_ids, ignored?)
      when is_list(transaction_ids) and transaction_ids != [] and is_boolean(ignored?) do
    transaction_ids = Enum.uniq(transaction_ids)

    transactions =
      Repo.all(
        from transaction in Transaction,
          where:
            transaction.org_id == ^org_id and transaction.statement_id == ^statement_id and
              transaction.id in ^transaction_ids and
              transaction.status not in ["queued", "posted", "verifying"]
      )

    Enum.each(transactions, fn transaction ->
      status =
        cond do
          ignored? -> "ignored"
          is_binary(transaction.counter_ledger_identity) -> "ready"
          true -> "unassigned"
        end

      transaction |> Ecto.Changeset.change(status: status, error: nil) |> Repo.update!()
    end)

    {:ok, transactions}
  end

  def set_ignored(_org_id, _statement_id, _transaction_ids, _ignored?),
    do: {:error, :invalid_transactions}

  defp replace_transactions(statement, transactions) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(transactions, fn transaction ->
        %{
          org_id: statement.org_id,
          statement_id: statement.id,
          identity: transaction["id"],
          ordinal: transaction["ordinal"],
          date: transaction_date!(transaction["date"]),
          narration: transaction["narration"] || "",
          reference: transaction["reference"],
          withdrawal_paise: transaction["withdrawal_paise"] || 0,
          deposit_paise: transaction["deposit_paise"] || 0,
          balance_paise: transaction["balance_paise"],
          transaction_type:
            if((transaction["withdrawal_paise"] || 0) != 0, do: "payment", else: "receipt"),
          status: "unassigned",
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Transaction, rows,
      on_conflict: :nothing,
      conflict_target: [:statement_id, :identity]
    )

    :ok
  end

  defp transaction_date!(%Date{} = date), do: date
  defp transaction_date!(date) when is_binary(date), do: Date.from_iso8601!(date)

  defp ensure_transaction_rows(
         %Statement{
           status: "ready",
           bank_transactions: [],
           transactions: [_ | _] = transactions
         } = statement
       ) do
    :ok = replace_transactions(statement, transactions)
    Repo.preload(statement, [bank_transactions: [:tally_job]], force: true)
  end

  defp ensure_transaction_rows(statement), do: statement

  defp ledger(org_id, company_id, identity) when is_binary(identity) do
    Repo.one(
      from master in SyncedMaster,
        where:
          master.org_id == ^org_id and master.company_id == ^company_id and
            master.kind == "ledger" and master.identity == ^identity
    )
  end

  defp ledger(_org_id, _company_id, _identity), do: nil

  defp bank_ledger(org_id, company_id, identity) do
    Enum.find(list_tally_bank_ledgers(org_id, company_id), &(&1.identity == identity))
  end

  defp ensure_distinct_ledger(statement, ledger) do
    if statement.bank_ledger_identity == ledger.identity,
      do: {:error, :same_ledger},
      else: :ok
  end

  defp editable_transactions(org_id, statement_id, ids) do
    ids = Enum.uniq(ids)

    Repo.all(
      from transaction in Transaction,
        where:
          transaction.org_id == ^org_id and transaction.statement_id == ^statement_id and
            transaction.id in ^ids and transaction.status in ["unassigned", "ready", "failed"],
        order_by: [asc: transaction.ordinal],
        lock: "FOR UPDATE"
    )
  end

  defp ready_transactions(org_id, statement_id, ids) do
    ids = Enum.uniq(ids)

    Repo.all(
      from transaction in Transaction,
        where:
          transaction.org_id == ^org_id and transaction.statement_id == ^statement_id and
            transaction.id in ^ids and transaction.status in ["ready", "failed"],
        order_by: [asc: transaction.ordinal]
    )
  end

  defp posting_started?(statement_id) do
    Repo.exists?(
      from transaction in Transaction,
        where:
          transaction.statement_id == ^statement_id and
            transaction.status in ["queued", "posted", "verifying"]
    )
  end

  defp ensure_posting_not_started(statement_id) do
    if posting_started?(statement_id), do: {:error, :posting_already_started}, else: :ok
  end

  defp refresh_job_states(statement) do
    Enum.each(statement.bank_transactions, fn transaction ->
      case transaction.tally_job do
        nil ->
          :ok

        job ->
          status = job_status(job.status)

          attrs =
            %{status: status, error: if(job.status in ["failed", "indeterminate"], do: job.error)}
            |> maybe_put_result(job)

          if transaction.status != status or result_changed?(transaction, attrs) do
            transaction |> Ecto.Changeset.change(attrs) |> Repo.update!()
          end
      end
    end)

    Repo.preload(statement, [bank_transactions: [:tally_job]], force: true)
  end

  defp maybe_put_result(attrs, %{status: "succeeded", result: result}) when is_map(result) do
    attrs
    |> Map.put(:tally_master_id, result["last_voucher_id"] || result["master_id"])
    |> Map.put(:tally_guid, result["guid"])
  end

  defp maybe_put_result(attrs, _job), do: attrs

  defp result_changed?(transaction, attrs) do
    (Map.has_key?(attrs, :tally_master_id) and
       transaction.tally_master_id != attrs.tally_master_id) or
      (Map.has_key?(attrs, :tally_guid) and transaction.tally_guid != attrs.tally_guid) or
      transaction.error != attrs.error
  end

  defp job_status(status) when status in ["pending", "running"], do: "queued"
  defp job_status("succeeded"), do: "posted"
  defp job_status("failed"), do: "failed"
  defp job_status("indeterminate"), do: "verifying"

  def mark_failed(%Statement{} = statement, reason) do
    statement
    |> Ecto.Changeset.change(
      status: "failed",
      source_credentials: nil,
      error: failure_message(reason)
    )
    |> Repo.update!()
  end

  def subscribe(org_id),
    do: Phoenix.PubSub.subscribe(Nila.PubSub, "bank_statements:#{org_id}")

  def broadcast(%Statement{} = statement, state) do
    Phoenix.PubSub.broadcast(
      Nila.PubSub,
      "bank_statements:#{statement.org_id}",
      {:bank_statement_progress, statement.id, state}
    )
  end

  defp failure_message(:password_required),
    do: "The PDF password was not accepted. Bring in the original statement and try again."

  defp failure_message(:not_text_pdf),
    do: "This PDF has no usable text layer. Bring in the bank-generated PDF, not a scan."

  defp failure_message(:unsupported_statement),
    do: "This does not look like the selected bank's statement."

  defp failure_message(:statement_does_not_tally),
    do: "The extracted transactions do not reconcile to the printed running balance."

  defp failure_message({:statement_does_not_tally, _ordinal, _expected, _printed}),
    do: failure_message(:statement_does_not_tally)

  defp failure_message(:duplicate_statement),
    do: "This exact statement was already brought into Nila for this client."

  defp failure_message(_reason),
    do: "Nila could not read this statement. Try the original PDF again."
end
