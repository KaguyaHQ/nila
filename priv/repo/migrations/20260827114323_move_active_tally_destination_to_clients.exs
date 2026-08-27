defmodule Nila.Repo.Migrations.MoveActiveTallyDestinationToClients do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      add :active_tally_company_id, references(:tally_companies, on_delete: :nilify_all)
    end

    execute("""
    UPDATE clients AS client
    SET active_tally_company_id = company.id
    FROM tally_companies AS company
    INNER JOIN (
      SELECT client_id
      FROM tally_companies
      WHERE client_id IS NOT NULL
      GROUP BY client_id
      HAVING COUNT(*) = 1
    ) AS unambiguous ON unambiguous.client_id = company.client_id
    WHERE client.id = company.client_id
    """)

    create unique_index(:clients, [:active_tally_company_id],
             where: "active_tally_company_id IS NOT NULL"
           )

    drop index(:tally_companies, [:client_id])

    alter table(:tally_companies) do
      remove :client_id
    end
  end

  def down do
    alter table(:tally_companies) do
      add :client_id, references(:clients, on_delete: :nilify_all)
    end

    create index(:tally_companies, [:client_id])

    execute("""
    UPDATE tally_companies AS company
    SET client_id = client.id
    FROM clients AS client
    WHERE client.active_tally_company_id = company.id
    """)

    drop index(:clients, [:active_tally_company_id])

    alter table(:clients) do
      remove :active_tally_company_id
    end
  end
end
