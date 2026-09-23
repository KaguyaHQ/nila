defmodule Nila.Repo.Migrations.AddBusinessInvoicingTables do
  use Ecto.Migration

  def change do
    create table(:business_profiles) do
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :legal_name, :text, null: false
      add :address, :text, null: false
      add :state_code, :string, null: false
      add :e_invoice_not_applicable, :boolean, null: false, default: false
      add :domestic_services_only, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:business_profiles, [:client_id])

    create table(:business_customers) do
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :name, :text, null: false
      add :address, :text, null: false
      add :gstin, :string
      add :state_code, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:business_customers, [:client_id])

    create table(:business_invoices) do
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :customer_id, references(:business_customers, on_delete: :restrict), null: false
      add :created_by_id, references(:users, on_delete: :restrict), null: false
      add :issued_by_id, references(:users, on_delete: :restrict)
      add :original_invoice_id, references(:business_invoices, on_delete: :restrict)
      add :dump_id, references(:gst_dumps, on_delete: :restrict)
      add :status, :string, null: false, default: "draft"
      add :document_type, :string, null: false, default: "invoice"
      add :number, :string
      add :invoice_date, :date, null: false
      add :due_date, :date
      add :place_of_supply, :string, null: false
      add :lines, {:array, :map}, null: false, default: []
      add :notes, :text
      add :snapshot, :map, null: false, default: %{}
      add :totals, :map, null: false, default: %{}
      add :pdf_key, :text
      add :pdf_sha256, :string
      add :issued_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:business_invoices, [:client_id, :invoice_date])
    create unique_index(:business_invoices, [:client_id, :number])
    create unique_index(:business_invoices, [:dump_id])

    create table(:business_invoice_counters) do
      add :client_id, references(:clients, on_delete: :restrict), null: false
      add :financial_year, :integer, null: false
      add :document_type, :string, null: false
      add :last_number, :integer, null: false, default: 0
    end

    create unique_index(:business_invoice_counters, [:client_id, :financial_year, :document_type],
             name: :business_invoice_counter_identity
           )
  end
end
