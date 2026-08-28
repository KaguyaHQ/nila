defmodule Nila.Repo.Migrations.PersistSalesBatchesAndTallyJobDestinations do
  use Ecto.Migration

  def up do
    create table(:gst_sales_batches) do
      add :org_id, references(:orgs, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :tally_company_id, references(:tally_companies, on_delete: :nilify_all)
      add :import_ref, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gst_sales_batches, [:org_id, :client_id, :inserted_at])
    create index(:gst_sales_batches, [:org_id, :tally_company_id])

    alter table(:gst_dumps) do
      add :sales_batch_id, references(:gst_sales_batches, on_delete: :nilify_all)
    end

    create index(:gst_dumps, [:sales_batch_id])

    alter table(:tally_jobs) do
      add :company_id, references(:tally_companies, on_delete: :nilify_all)
      add :sales_batch_id, references(:gst_sales_batches, on_delete: :nilify_all)
    end

    create index(:tally_jobs, [:company_id, :status, :id])
    create index(:tally_jobs, [:sales_batch_id, :id])
    flush()

    backfill_job_companies()
    backfill_sales_batches()
    backfill_bank_job_companies()
  end

  def down do
    alter table(:tally_jobs) do
      remove :sales_batch_id
      remove :company_id
    end

    alter table(:gst_dumps) do
      remove :sales_batch_id
    end

    drop table(:gst_sales_batches)
  end

  defp backfill_job_companies do
    execute("""
    UPDATE tally_jobs AS job
    SET company_id = company.id
    FROM tally_companies AS company
    WHERE job.company_id IS NULL
      AND company.org_id = job.org_id
      AND company.tally_guid IS NOT NULL
      AND company.tally_guid = job.payload->>'company_guid'
    """)

    execute("""
    UPDATE tally_jobs AS job
    SET company_id = candidate.id
    FROM (
      SELECT company.org_id, company.name, min(company.id) AS id
      FROM tally_companies AS company
      GROUP BY company.org_id, company.name
      HAVING count(*) = 1
    ) AS candidate
    WHERE job.company_id IS NULL
      AND candidate.org_id = job.org_id
      AND candidate.name = job.payload->>'company'
    """)
  end

  defp backfill_sales_batches do
    %{rows: dumps} =
      repo().query!("""
      SELECT id, org_id, client_id, meta, inserted_at, updated_at
      FROM gst_dumps
      WHERE kind = 'sales'
      ORDER BY id
      """)

    %{rows: job_rows} =
      repo().query!("""
      SELECT id, org_id, source_key, company_id
      FROM tally_jobs
      WHERE source_key LIKE 'sales-bills:%'
      ORDER BY id
      """)

    jobs_by_org = Enum.group_by(job_rows, &Enum.at(&1, 1))

    dumps
    |> Enum.group_by(fn [id, org_id, client_id, meta, _inserted_at, _updated_at] ->
      import_ref = Map.get(meta || %{}, "sales_import_ref") || "dump:#{id}"
      {org_id, client_id, import_ref}
    end)
    |> Enum.each(fn {{org_id, client_id, import_ref}, batch_dumps} ->
      batch_ref = batch_dumps |> Enum.map(&hd/1) |> Enum.join("-")
      prefix = legacy_sales_prefix(batch_ref)

      batch_jobs =
        jobs_by_org
        |> Map.get(org_id, [])
        |> Enum.filter(fn [_id, _org_id, source_key, _company_id] ->
          String.starts_with?(source_key || "", prefix)
        end)

      company_ids =
        batch_jobs
        |> Enum.map(fn [_id, _org_id, source_key, company_id] ->
          company_id || company_id_from_source_key(prefix, source_key)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      company_id =
        case company_ids do
          [] ->
            nil

          [company_id] ->
            company_id

          ids ->
            raise "sales batch #{batch_ref} has Tally jobs for multiple companies: #{inspect(ids)}"
        end

      inserted_at = batch_dumps |> hd() |> Enum.at(4)
      updated_at = batch_dumps |> List.last() |> Enum.at(5)

      %{rows: [[batch_id]]} =
        repo().query!(
          """
          INSERT INTO gst_sales_batches
            (org_id, client_id, tally_company_id, import_ref, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6)
          RETURNING id
          """,
          [org_id, client_id, company_id, import_ref, inserted_at, updated_at]
        )

      Enum.each(batch_dumps, fn [dump_id | _rest] ->
        repo().query!("UPDATE gst_dumps SET sales_batch_id = $1 WHERE id = $2", [
          batch_id,
          dump_id
        ])
      end)

      Enum.each(batch_jobs, fn [job_id, _org_id, _source_key, _company_id] ->
        repo().query!(
          """
          UPDATE tally_jobs
          SET sales_batch_id = $1,
              company_id = coalesce(company_id, $2)
          WHERE id = $3
          """,
          [batch_id, company_id, job_id]
        )
      end)
    end)
  end

  defp backfill_bank_job_companies do
    execute("""
    UPDATE tally_jobs AS job
    SET company_id = statement.tally_company_id
    FROM bank_transactions AS transaction
    JOIN bank_statements AS statement ON statement.id = transaction.statement_id
    WHERE transaction.tally_job_id = job.id
      AND job.company_id IS NULL
      AND statement.tally_company_id IS NOT NULL
    """)
  end

  defp legacy_sales_prefix(batch_ref) do
    digest =
      batch_ref
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "sales-bills:#{digest}:company:"
  end

  defp company_id_from_source_key(prefix, source_key) do
    with true <- String.starts_with?(source_key || "", prefix),
         remainder <- String.replace_prefix(source_key, prefix, ""),
         [company_id, "voucher", _source_id] <- String.split(remainder, ":", parts: 3),
         {company_id, ""} when company_id > 0 <- Integer.parse(company_id) do
      company_id
    else
      _ -> nil
    end
  end
end
