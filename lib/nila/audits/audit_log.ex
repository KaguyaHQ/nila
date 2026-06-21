defmodule Nila.Audits.AuditLog do
  use Nila.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :integer
    field :metadata, :map, default: %{}

    belongs_to :org, Nila.Orgs.Org
    belongs_to :actor, Nila.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:org_id, :actor_id, :action, :entity_type, :entity_id, :metadata])
    |> validate_required([:org_id, :action, :entity_type, :entity_id, :metadata])
  end
end
