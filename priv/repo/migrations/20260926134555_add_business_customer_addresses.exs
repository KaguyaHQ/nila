defmodule Nila.Repo.Migrations.AddBusinessCustomerAddresses do
  use Ecto.Migration

  def up do
    create table(:business_customer_addresses) do
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :customer_id, references(:business_customers, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :address, :text, null: false
      add :state_code, :string, null: false
      add :gstin, :string
      add :usage, :string, null: false, default: "either"
      add :is_primary_billing, :boolean, null: false, default: false
      add :is_primary_shipping, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:business_customer_addresses, [:client_id, :customer_id])

    create unique_index(:business_customer_addresses, [:customer_id],
             where: "is_primary_billing",
             name: :business_customer_addresses_primary_billing
           )

    create unique_index(:business_customer_addresses, [:customer_id],
             where: "is_primary_shipping",
             name: :business_customer_addresses_primary_shipping
           )

    create constraint(:business_customer_addresses, :business_customer_addresses_usage,
             check: "usage IN ('billing', 'shipping', 'either')"
           )

    execute("""
    INSERT INTO business_customer_addresses
      (client_id, customer_id, label, address, state_code, gstin, usage,
       is_primary_billing, is_primary_shipping, inserted_at, updated_at)
    SELECT client_id, id, 'Primary address', address, state_code, gstin, 'either',
           true, true, inserted_at, updated_at
    FROM business_customers
    """)

    alter table(:business_invoices) do
      add :billing_address_id, references(:business_customer_addresses, on_delete: :restrict)
      add :shipping_address_id, references(:business_customer_addresses, on_delete: :restrict)
    end
  end

  def down do
    alter table(:business_invoices) do
      remove :billing_address_id
      remove :shipping_address_id
    end

    drop table(:business_customer_addresses)
  end
end
