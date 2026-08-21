defmodule Nila.Repo.Migrations.RemoveDuplicateSalesBillTallyJobs do
  use Ecto.Migration

  def up do
    execute("""
    WITH ranked AS (
      SELECT
        id,
        row_number() OVER (
          PARTITION BY
            org_id,
            regexp_replace(source_key, '[^:]+$', ''),
            payload->>'invoice_number'
          ORDER BY id DESC
        ) AS duplicate_rank
      FROM tally_jobs
      WHERE kind = 'import_vouchers'
        AND source_key LIKE 'sales-bills:%:voucher:%'
        AND payload->>'invoice_number' IS NOT NULL
    )
    DELETE FROM tally_jobs AS job
    USING ranked
    WHERE job.id = ranked.id
      AND ranked.duplicate_rank > 1
    """)
  end

  def down, do: :ok
end
