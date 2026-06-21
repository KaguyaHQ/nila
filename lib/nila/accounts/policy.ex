defmodule Nila.Accounts.Policy do
  @moduledoc """
  The single capability map for workspace roles.

  Roles live on the `Nila.Orgs.Membership` joining a user to an org, and are
  carried on the current `Nila.Accounts.Scope`. There are four roles, forming a
  tier from most to least privileged:

      owner ─ admin ─ member (operator) ─ viewer

  - **owner / admin** manage everything: users, settings, connectors, records.
  - **member** is the operator (e.g. Jaimathi): runs jobs, invoices, payments,
    approvals and sends messages, but cannot manage users, settings, or inboxes.
  - **viewer** (e.g. the CA later): read and export only.

  `admin` is kept as a synonym for `owner` so the enum the schema already ships
  with stays stable; the family MVP only needs owner / operator / viewer.

  Authorize with `can?/2`. Web guards (`NilaWeb.UserAuth`) delegate here so the
  rules live in one place.
  """

  alias Nila.Accounts.Scope

  @all_capabilities ~w(
    view edit_records send_messages export
    manage_settings manage_connectors manage_users
  )a

  @role_capabilities %{
    "owner" => :all,
    "admin" => :all,
    "member" => ~w(view edit_records send_messages export)a,
    "viewer" => ~w(view export)a
  }

  @doc "Every capability the system knows about."
  def capabilities, do: @all_capabilities

  @doc """
  Returns true when the scope's membership role grants `capability`.

  An absent scope or membership grants nothing.
  """
  def can?(%Scope{membership: %{role: role}}, capability)
      when capability in @all_capabilities,
      do: granted?(role, capability)

  def can?(_scope, _capability), do: false

  defp granted?(role, capability) do
    case Map.get(@role_capabilities, role) do
      :all -> true
      caps when is_list(caps) -> capability in caps
      _ -> false
    end
  end

  @doc "Roles assignable through the UI, as `{label, value}` pairs for selects."
  def assignable_roles do
    [{"Owner", "owner"}, {"Admin", "admin"}, {"Operator", "member"}, {"Viewer", "viewer"}]
  end

  @doc "Human label for a stored role value."
  def role_label("owner"), do: "Owner"
  def role_label("admin"), do: "Admin"
  def role_label("member"), do: "Operator"
  def role_label("viewer"), do: "Viewer"
  def role_label(other) when is_binary(other), do: String.capitalize(other)
end
