defmodule Nila.Accounts.Policy do
  @moduledoc """
  The single capability map for firm roles.

  Roles live on the `Nila.Orgs.Membership` joining a user to a firm (org), and
  are carried on the current `Nila.Accounts.Scope`. There are four roles, forming
  a tier from most to least privileged:

      owner ─ admin ─ member (operator) ─ viewer

  - **owner / admin** manage everything: the firm's staff, settings, connectors,
    and all client records — and are the only roles that can sign off a month
    (maker-checker: the operator who worked the month cannot self-certify).
  - **member** is the operator (the junior accountant): works client months,
    resolves exceptions, and sends messages, but cannot manage staff or settings
    and cannot sign off.
  - **viewer**: read and export only.

  `admin` is kept as a synonym for `owner` so the enum the schema already ships
  with stays stable.

  Authorize with `can?/2`. Web guards (`NilaWeb.UserAuth`) delegate here so the
  rules live in one place.
  """

  alias Nila.Accounts.Scope

  @all_capabilities ~w(
    view edit_records send_messages export sign_off
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

  @doc """
  Roles assignable through the UI, as `{label, value}` pairs for selects.

  `admin` is omitted: it is a behavioural synonym for `owner`, so offering both
  is a choice with no consequence. Existing `admin` memberships still resolve
  through `role_label/1` and `can?/2`.
  """
  def assignable_roles do
    [{"Owner", "owner"}, {"Operator", "member"}, {"Viewer", "viewer"}]
  end

  @doc "Human label for a stored role value."
  def role_label("owner"), do: "Owner"
  def role_label("admin"), do: "Admin"
  def role_label("member"), do: "Operator"
  def role_label("viewer"), do: "Viewer"
  def role_label(other) when is_binary(other), do: String.capitalize(other)

  @doc "One-line description of what a role can do, for the UI."
  def role_description("owner"), do: "Manages the firm, staff, settings, and all client work."
  def role_description("admin"), do: "Manages the firm, staff, settings, and all client work."

  def role_description("member"),
    do: "Works client months and resolves exceptions; no staff or settings access."

  def role_description("viewer"), do: "Reads and exports only."
  def role_description(_other), do: ""
end
