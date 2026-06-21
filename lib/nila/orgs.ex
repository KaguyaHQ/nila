defmodule Nila.Orgs do
  import Ecto.Query

  alias Nila.Orgs.{Entity, Membership, Org}
  alias Nila.Repo

  def list_orgs do
    Repo.all(from org in Org, order_by: [asc: org.name])
  end

  def get_org!(id), do: Repo.get!(Org, id)

  def create_org(attrs) do
    %Org{}
    |> Org.changeset(attrs)
    |> Repo.insert()
  end

  def create_org!(attrs) do
    %Org{}
    |> Org.changeset(attrs)
    |> Repo.insert!()
  end

  def update_org(%Org{} = org, attrs) do
    org
    |> Org.changeset(attrs)
    |> Repo.update()
  end

  def list_entities(org_id) do
    Repo.all(from entity in Entity, where: entity.org_id == ^org_id, order_by: [asc: entity.name])
  end

  def default_entity(org_id) do
    Entity
    |> where([entity], entity.org_id == ^org_id)
    |> order_by([entity], asc: entity.id)
    |> limit(1)
    |> Repo.fetch_one()
  end

  def get_or_create_default_entity!(org_id) do
    case default_entity(org_id) do
      {:ok, entity} ->
        entity

      {:error, :not_found} ->
        org = get_org!(org_id)

        %Entity{}
        |> Entity.changeset(%{
          org_id: org.id,
          name: org.legal_name || org.name,
          gstin: org.gstin,
          invoice_prefix: "",
          invoice_next: 1,
          invoice_padding: 0
        })
        |> Repo.insert!()
    end
  end

  def get_entity(id), do: Repo.fetch(Entity, id)

  def get_entity!(id), do: Repo.get!(Entity, id)

  def create_entity(attrs) do
    %Entity{}
    |> Entity.changeset(attrs)
    |> Repo.insert()
  end

  def update_entity(%Entity{} = entity, attrs) do
    entity
    |> Entity.changeset(attrs)
    |> Repo.update()
  end

  def change_entity(%Entity{} = entity, attrs \\ %{}) do
    Entity.changeset(entity, attrs)
  end

  def formatted_invoice_number(%Entity{} = entity, date \\ Date.utc_today()) do
    sequence =
      entity.invoice_next
      |> Integer.to_string()
      |> String.pad_leading(entity.invoice_padding || 0, "0")

    fiscal_year = fiscal_year_label(date, entity.fiscal_year_start_month || 4)

    "#{entity.invoice_prefix || ""}#{sequence}/#{fiscal_year}"
  end

  @doc """
  Atomically consumes the entity's next invoice number and returns it formatted.

  Uses `UPDATE org_entities SET invoice_next = invoice_next + 1 RETURNING *` inside
  a transaction so concurrent callers cannot collide on the same number. The Postgres
  RETURNING clause yields the POST-update row; the number we just consumed is
  `invoice_next - 1`. Tested for sequentialness under contention in
  `test/nila/orgs_test.exs`.

  Returns `{:ok, "PREFIX0001/25-26"}` or `{:error, :entity_not_found}`.
  """
  def assign_next_invoice_number(entity_or_id, date \\ Date.utc_today())

  def assign_next_invoice_number(%Entity{id: id}, date),
    do: assign_next_invoice_number(id, date)

  def assign_next_invoice_number(entity_id, %Date{} = date) when is_integer(entity_id) do
    Repo.transact(fn ->
      case Repo.update_all(
             from(e in Entity, where: e.id == ^entity_id, select: e),
             inc: [invoice_next: 1]
           ) do
        {1, [post_update]} ->
          consumed = %{post_update | invoice_next: post_update.invoice_next - 1}
          {:ok, formatted_invoice_number(consumed, date)}

        {0, _} ->
          {:error, :entity_not_found}
      end
    end)
  end

  def add_user(%Org{} = org, user_id, role \\ "member") do
    %Membership{}
    |> Membership.changeset(%{org_id: org.id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  @doc """
  Lists an org's memberships with their users, ordered by member name.
  """
  def list_memberships(org_id) do
    Repo.all(
      from membership in Membership,
        join: user in assoc(membership, :user),
        where: membership.org_id == ^org_id,
        order_by: [asc: user.name],
        preload: [user: user]
    )
  end

  def get_membership!(id), do: Repo.get!(Membership, id)

  @doc """
  Updates a membership's role.

  Refuses to demote the last owner of an org so a workspace can never be left
  without one. Returns `{:error, :last_owner}` in that case.
  """
  def update_membership_role(%Membership{} = membership, role) do
    if demoting_last_owner?(membership, role) do
      {:error, :last_owner}
    else
      membership
      |> Membership.role_changeset(role)
      |> Repo.update()
    end
  end

  @doc "Counts the owner memberships in an org."
  def owner_count(org_id) do
    Repo.aggregate(
      from(membership in Membership,
        where: membership.org_id == ^org_id and membership.role == "owner"
      ),
      :count
    )
  end

  defp demoting_last_owner?(%Membership{role: "owner", org_id: org_id}, new_role)
       when new_role != "owner",
       do: owner_count(org_id) <= 1

  defp demoting_last_owner?(_membership, _new_role), do: false

  def change_org(%Org{} = org, attrs \\ %{}) do
    Org.changeset(org, attrs)
  end

  @doc """
  Deletes all work data for an org: documents (and their artifacts), audit logs,
  and workflow runs (and their steps). Preserves the org, its entities, and
  users/memberships.

  Returns `{:ok, total_deleted}`.
  """
  def delete_all_work_data(org_id) do
    Repo.transact(fn ->
      # Documents cascade to document_artifacts.
      {docs, _} = Repo.delete_all(from(d in Nila.Documents.Document, where: d.org_id == ^org_id))

      # Audit logs.
      {audits, _} = Repo.delete_all(from(al in Nila.Audits.AuditLog, where: al.org_id == ^org_id))

      # Workflow runs cascade to workflow_steps.
      {runs, _} = Repo.delete_all(from(wr in Nila.Workflows.Run, where: wr.org_id == ^org_id))

      {:ok, docs + audits + runs}
    end)
  end

  @doc """
  The Indian fiscal-year label (`"2026-27"`) for `date` under `entity`'s
  fiscal-year start month.
  """
  def fiscal_year_for(%Entity{} = entity, date \\ Date.utc_today()),
    do: fiscal_year_label(date, entity.fiscal_year_start_month || 4)

  defp fiscal_year_label(%Date{} = date, 4) do
    start_year =
      if date.month >= 4 do
        date.year
      else
        date.year - 1
      end

    "#{start_year}-#{rem(start_year + 1, 100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
