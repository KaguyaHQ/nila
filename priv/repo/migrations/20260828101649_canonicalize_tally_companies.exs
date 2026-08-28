defmodule Nila.Repo.Migrations.CanonicalizeTallyCompanies do
  use Ecto.Migration

  def up do
    create table(:tally_company_devices) do
      add :company_id, references(:tally_companies, on_delete: :delete_all), null: false
      add :device_id, references(:tally_devices, on_delete: :delete_all), null: false
      add :is_open, :boolean, null: false, default: false
      add :last_seen_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tally_company_devices, [:company_id, :device_id])
    create index(:tally_company_devices, [:device_id, :is_open])

    execute """
    UPDATE tally_companies
    SET identity = 'device:' || device_id || ':' || identity
    WHERE identity LIKE 'name:%'
    """

    execute """
    INSERT INTO tally_company_devices
      (company_id, device_id, is_open, last_seen_at, inserted_at, updated_at)
    SELECT id, device_id, is_open, last_seen_at, inserted_at, updated_at
    FROM tally_companies
    """

    execute """
    CREATE TEMP TABLE tally_company_merge AS
    WITH ranked AS (
      SELECT company.id,
             first_value(company.id) OVER (
               PARTITION BY company.org_id, company.identity
               ORDER BY EXISTS (
                 SELECT 1 FROM clients
                 WHERE clients.active_tally_company_id = company.id
               ) DESC, company.id
             ) AS canonical_id
      FROM tally_companies AS company
    )
    SELECT id AS duplicate_id, canonical_id
    FROM ranked
    WHERE id <> canonical_id
    """

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM clients a
        JOIN tally_company_merge m ON m.duplicate_id = a.active_tally_company_id
        JOIN clients b ON b.active_tally_company_id = m.canonical_id
      ) THEN
        RAISE EXCEPTION 'Cannot merge Tally companies linked to different Nila clients';
      END IF;
    END $$
    """

    execute "UPDATE clients SET active_tally_company_id = m.canonical_id FROM tally_company_merge m WHERE active_tally_company_id = m.duplicate_id"

    execute "UPDATE bank_statements SET tally_company_id = m.canonical_id FROM tally_company_merge m WHERE tally_company_id = m.duplicate_id"

    execute "UPDATE tally_sync_runs SET company_id = m.canonical_id FROM tally_company_merge m WHERE company_id = m.duplicate_id"

    merge_unique_rows("tally_company_devices", "device_id")
    merge_unique_rows("tally_synced_masters", "kind, identity")
    merge_unique_rows("tally_synced_vouchers", "identity")
    merge_unique_rows("tally_party_mappings", "source_key")
    merge_unique_rows("tally_sales_line_mappings", "source_key")
    merge_unique_rows("tally_posting_profiles", "")

    execute "DELETE FROM tally_companies c USING tally_company_merge m WHERE c.id = m.duplicate_id"

    drop_if_exists unique_index(:tally_companies, [:device_id, :identity])
    drop_if_exists index(:tally_companies, [:device_id])
    drop_if_exists index(:tally_companies, [:org_id, :is_open])

    alter table(:tally_companies) do
      remove :device_id
      remove :is_open
      remove :last_seen_at
    end

    create unique_index(:tally_companies, [:org_id, :identity])
  end

  def down do
    raise "canonical Tally company merges cannot be reversed safely"
  end

  defp merge_unique_rows(table, suffix) do
    equality =
      suffix
      |> String.split(",", trim: true)
      |> Enum.map_join(" AND ", fn column ->
        column = String.trim(column)
        "winner.#{column} = loser.#{column}"
      end)

    equality = if equality == "", do: "TRUE", else: equality

    execute """
    DELETE FROM #{table} AS loser
    USING tally_company_merge AS m, #{table} AS winner
    WHERE loser.company_id = m.duplicate_id
      AND winner.company_id = m.canonical_id
      AND #{equality}
      AND winner.updated_at >= loser.updated_at
    """

    execute """
    DELETE FROM #{table} AS winner
    USING tally_company_merge AS m, #{table} AS loser
    WHERE winner.company_id = m.canonical_id
      AND loser.company_id = m.duplicate_id
      AND #{equality}
      AND winner.updated_at < loser.updated_at
    """

    execute """
    UPDATE #{table} AS row
    SET company_id = m.canonical_id
    FROM tally_company_merge AS m
    WHERE row.company_id = m.duplicate_id
    """
  end
end
