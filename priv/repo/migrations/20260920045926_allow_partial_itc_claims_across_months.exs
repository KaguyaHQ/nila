defmodule Nila.Repo.Migrations.AllowPartialItcClaimsAcrossMonths do
  use Ecto.Migration

  def change do
    drop unique_index(:gst_itc_allocations, [:case_id, :kind],
           where: "revoked_at IS NULL",
           name: :gst_itc_allocations_live_entitlement_index
         )

    create unique_index(:gst_itc_allocations, [:case_id, :client_month_id, :kind],
             where: "revoked_at IS NULL",
             name: :gst_itc_allocations_live_entitlement_index
           )
  end
end
