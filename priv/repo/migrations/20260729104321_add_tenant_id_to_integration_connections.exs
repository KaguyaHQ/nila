defmodule Nila.Repo.Migrations.AddTenantIdToIntegrationConnections do
  use Ecto.Migration

  def change do
    alter table(:integration_connections) do
      add :tenant_id, :string
    end

    # A Microsoft tenant grants Nila send rights across its mailboxes, so it may
    # bind to exactly one workspace. Scoping this per org would let a second org
    # claim a tenant that already consented elsewhere.
    create unique_index(:integration_connections, [:provider, :tenant_id],
             where: "tenant_id is not null",
             name: :integration_connections_provider_tenant_id_index
           )
  end
end
