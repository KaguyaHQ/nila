defmodule Mix.Tasks.Nila.InviteFirmTest do
  use Nila.DataCase, async: false

  import ExUnit.CaptureIO
  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Orgs.Membership
  alias Nila.Repo

  setup do
    Mix.Task.reenable("nila.invite_firm")
    :ok
  end

  test "creates the firm and sends its first-owner invitation" do
    email = unique_user_email()
    firm_name = "Task Firm #{System.unique_integer([:positive])}"

    output =
      capture_io(fn ->
        Mix.Task.run("nila.invite_firm", [
          "--firm",
          firm_name,
          "--name",
          "Task Owner",
          "--email",
          email
        ])
      end)

    assert output =~ "Created #{firm_name} and sent an invitation to #{email}."

    user = Accounts.get_user_by_email(email)
    membership = Repo.get_by!(Membership, user_id: user.id)
    assert membership.role == "owner"
    assert_email_sent(to: [{nil, email}])
  end

  test "requires all operator inputs" do
    assert_raise Mix.Error, ~r/Missing required options: --name, --email/, fn ->
      Mix.Task.run("nila.invite_firm", ["--firm", "Incomplete Firm"])
    end
  end
end
