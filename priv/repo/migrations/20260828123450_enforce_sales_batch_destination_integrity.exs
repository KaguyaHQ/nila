defmodule Nila.Repo.Migrations.EnforceSalesBatchDestinationIntegrity do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:gst_sales_batches, [:org_id, :import_ref])

    create unique_index(:gst_sales_batches, [:org_id, :client_id, :import_ref])

    flush()
    backfill_jobs_by_unique_invoice_number()
    flush()
    pin_batches_from_jobs()
    flush()
    assert_no_orphaned_sales_jobs!()
  end

  def down do
    drop unique_index(:gst_sales_batches, [:org_id, :client_id, :import_ref])
  end

  defp backfill_jobs_by_unique_invoice_number do
    execute("""
    WITH candidates AS (
      SELECT job.id AS job_id, min(dump.sales_batch_id) AS sales_batch_id
      FROM tally_jobs AS job
      JOIN gst_dumps AS dump
        ON dump.org_id = job.org_id
       AND dump.kind = 'sales'
       AND dump.sales_batch_id IS NOT NULL
      CROSS JOIN LATERAL unnest(dump.invoices) AS invoice
      WHERE job.source_key LIKE 'sales-bills:%'
        AND job.sales_batch_id IS NULL
        AND job.payload->>'invoice_number' IS NOT NULL
        AND invoice->>'invoice_number' = job.payload->>'invoice_number'
      GROUP BY job.id
      HAVING count(DISTINCT dump.sales_batch_id) = 1
    )
    UPDATE tally_jobs AS job
    SET sales_batch_id = candidate.sales_batch_id
    FROM candidates AS candidate
    WHERE job.id = candidate.job_id
    """)
  end

  defp pin_batches_from_jobs do
    execute("""
    WITH destinations AS (
      SELECT job.sales_batch_id, min(job.company_id) AS company_id
      FROM tally_jobs AS job
      WHERE job.sales_batch_id IS NOT NULL
        AND job.company_id IS NOT NULL
      GROUP BY job.sales_batch_id
      HAVING count(DISTINCT job.company_id) = 1
    )
    UPDATE gst_sales_batches AS batch
    SET tally_company_id = destination.company_id
    FROM destinations AS destination
    WHERE batch.id = destination.sales_batch_id
      AND batch.tally_company_id IS NULL
    """)

    flush()

    %{rows: rows} =
      repo().query!("""
      SELECT job.id
      FROM tally_jobs AS job
      JOIN gst_sales_batches AS batch ON batch.id = job.sales_batch_id
      WHERE job.source_key LIKE 'sales-bills:%'
        AND job.company_id IS DISTINCT FROM batch.tally_company_id
      ORDER BY job.id
      LIMIT 20
      """)

    if rows != [] do
      ids = Enum.map_join(rows, ", ", fn [id] -> to_string(id) end)
      raise "legacy Sales jobs disagree with their batch destination; job ids: #{ids}"
    end
  end

  defp assert_no_orphaned_sales_jobs! do
    %{rows: rows} =
      repo().query!("""
      SELECT id
      FROM tally_jobs
      WHERE source_key LIKE 'sales-bills:%'
        AND (sales_batch_id IS NULL OR company_id IS NULL)
      ORDER BY id
      LIMIT 20
      """)

    if rows != [] do
      ids = Enum.map_join(rows, ", ", fn [id] -> to_string(id) end)

      raise "legacy Sales Tally jobs could not be assigned safely; job ids: #{ids}"
    end
  end
end
