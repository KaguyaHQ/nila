defmodule Nila.Accounts.PolicyTest do
  use ExUnit.Case, async: true

  alias Nila.Accounts.Policy
  alias Nila.Accounts.Scope

  defp scope(role), do: %Scope{user: %{id: 1}, membership: %{role: role}}

  describe "can?/2" do
    test "owner and admin hold every capability" do
      for role <- ["owner", "admin"], capability <- Policy.capabilities() do
        assert Policy.can?(scope(role), capability),
               "expected #{role} to have #{capability}"
      end
    end

    test "operator (member) runs records but cannot manage the workspace" do
      operator = scope("member")

      assert Policy.can?(operator, :view)
      assert Policy.can?(operator, :edit_records)
      assert Policy.can?(operator, :send_messages)
      assert Policy.can?(operator, :export)

      refute Policy.can?(operator, :manage_users)
      refute Policy.can?(operator, :manage_settings)
      refute Policy.can?(operator, :manage_connectors)
      refute Policy.can?(operator, :sign_off)
    end

    test "viewer can only read and export" do
      viewer = scope("viewer")

      assert Policy.can?(viewer, :view)
      assert Policy.can?(viewer, :export)

      refute Policy.can?(viewer, :edit_records)
      refute Policy.can?(viewer, :send_messages)
      refute Policy.can?(viewer, :manage_users)
      refute Policy.can?(viewer, :sign_off)
    end

    test "an absent scope, membership, or unknown role grants nothing" do
      refute Policy.can?(nil, :view)
      refute Policy.can?(%Scope{membership: nil}, :view)
      refute Policy.can?(scope("ghost"), :view)
    end

    test "an unknown capability is always denied" do
      refute Policy.can?(scope("owner"), :nuke_everything)
    end
  end
end
