defmodule Nila.Audits do
  import Ecto.Query

  alias Nila.Audits.AuditLog
  alias Nila.Repo

  def list_for_org(org_id, limit \\ 100) do
    Repo.all(
      from audit_log in AuditLog,
        where: audit_log.org_id == ^org_id,
        order_by: [desc: audit_log.inserted_at],
        limit: ^limit,
        preload: [:actor]
    )
  end

  def record(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end
end
