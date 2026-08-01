defmodule Nila.Repo.Migrations.CreateGstRateRules do
  use Ecto.Migration

  def change do
    create table(:gst_rate_releases) do
      add :notification_number, :string, null: false
      add :tax_type, :string, null: false
      add :source_name, :string, null: false
      add :source_url, :text
      add :file_sha256, :string, null: false
      add :published_on, :date, null: false
      add :effective_from, :date, null: false
      add :status, :string, null: false, default: "staged"
      add :observed_at, :utc_datetime_usec, null: false
      add :activated_at, :utc_datetime_usec

      timestamps(updated_at: false)
    end

    create unique_index(:gst_rate_releases, [:file_sha256])

    create unique_index(:gst_rate_releases, [:status],
             where: "status = 'active'",
             name: :gst_rate_releases_one_active_index
           )

    create constraint(:gst_rate_releases, :gst_rate_releases_status_check,
             check: "status IN ('staged', 'active', 'superseded')"
           )

    create constraint(:gst_rate_releases, :gst_rate_releases_tax_type_check,
             check: "tax_type IN ('integrated')"
           )

    create table(:gst_rate_rules) do
      add :release_id, references(:gst_rate_releases, on_delete: :delete_all), null: false
      add :serial_number, :integer, null: false
      add :schedule, :string, null: false
      add :total_rate, :decimal, precision: 7, scale: 4, null: false
      add :raw_code_expression, :text, null: false
      add :raw_description, :text, null: false
      add :parsed_scope, :map, null: false
      add :parser_confidence, :string, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:gst_rate_rules, [:release_id, :schedule, :serial_number])
    create index(:gst_rate_rules, [:release_id])

    create constraint(:gst_rate_rules, :gst_rate_rules_parser_confidence_check,
             check: "parser_confidence IN ('automatic', 'review')"
           )

    alter table(:sales_months) do
      add :gst_rate_release_id, references(:gst_rate_releases, on_delete: :nilify_all)
    end

    alter table(:client_months) do
      add :gst_rate_release_id, references(:gst_rate_releases, on_delete: :nilify_all)
    end

    create index(:sales_months, [:gst_rate_release_id])
    create index(:client_months, [:gst_rate_release_id])
  end
end
