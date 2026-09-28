defmodule Nila.Repo.Migrations.AddBusinessInvoiceCancellation do
  use Ecto.Migration

  def change do
    alter table(:business_invoices) do
      add :cancelled_at, :utc_datetime_usec
      add :cancelled_by_id, references(:users, on_delete: :restrict)
      add :cancellation_reason, :text
    end

    create constraint(:business_invoices, :business_invoice_cancellation_complete,
             check:
               "(cancelled_at IS NULL AND cancelled_by_id IS NULL AND cancellation_reason IS NULL) OR " <>
                 "(cancelled_at IS NOT NULL AND cancelled_by_id IS NOT NULL AND cancellation_reason IS NOT NULL)"
           )

    create constraint(:business_invoices, :business_invoice_cancellation_reason_length,
             check:
               "cancellation_reason IS NULL OR " <>
                 "(length(btrim(cancellation_reason)) BETWEEN 1 AND 500)"
           )
  end
end
