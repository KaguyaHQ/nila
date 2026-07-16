defmodule Nila.Repo.Migrations.AddFiledMarksToMonths do
  use Ecto.Migration

  def change do
    alter table(:client_months) do
      add :filed_at, :utc_datetime_usec
      add :filed_by_id, references(:users)
      add :filing_arn, :string
    end

    alter table(:sales_months) do
      add :filed_at, :utc_datetime_usec
      add :filed_by_id, references(:users)
      add :filing_arn, :string
    end
  end
end
