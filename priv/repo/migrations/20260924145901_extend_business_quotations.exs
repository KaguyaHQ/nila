defmodule Nila.Repo.Migrations.ExtendBusinessQuotations do
  use Ecto.Migration

  def change do
    alter table(:business_profiles) do
      add :phone, :string
      add :email, :string
      add :logo_key, :text
      add :signature_key, :text
      add :quotation_number_style, :string, null: false, default: "nila"
    end

    alter table(:business_invoices) do
      add :subject, :string
      add :delivery_state_code, :string
      add :revised_from_id, references(:business_invoices, on_delete: :restrict)
    end

    create index(:business_invoices, [:revised_from_id])
  end
end
