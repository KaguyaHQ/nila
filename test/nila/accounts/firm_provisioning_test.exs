defmodule Nila.Accounts.FirmProvisioningTest do
  use Nila.DataCase, async: false

  import Nila.AccountsFixtures
  import Swoosh.TestAssertions

  alias Nila.Accounts
  alias Nila.Accounts.User
  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  defp url_fun do
    test_pid = self()

    fn token ->
      send(test_pid, {:invite_token, token})
      "http://localhost/users/invite/#{token}"
    end
  end

  describe "provision_firm/3" do
    test "atomically creates a firm, passwordless owner, and one-time invitation" do
      firm_name = "Raman & Associates #{System.unique_integer([:positive])}"
      email = unique_user_email()

      assert {:ok, %{user: user, org: org, membership: membership}} =
               Accounts.provision_firm(
                 %{name: firm_name},
                 %{name: "Anita Raman", email: email},
                 url_fun()
               )

      assert user.email == email
      assert user.name == "Anita Raman"
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert org.name == firm_name
      assert membership.user_id == user.id
      assert membership.org_id == org.id
      assert membership.role == "owner"

      assert_received {:invite_token, token}
      assert Accounts.get_user_by_invite_token(token).id == user.id

      assert_email_sent(fn sent ->
        assert sent.to == [{"", email}]
        assert sent.text_body =~ "/users/invite/#{token}"
        assert sent.text_body =~ firm_name
      end)
    end

    test "rejects an existing email and rolls back the firm" do
      existing = user_fixture()
      before_orgs = Repo.aggregate(Org, :count)

      assert {:error, changeset} =
               Accounts.provision_firm(
                 %{name: "Duplicate Email Firm"},
                 %{name: "Existing User", email: existing.email},
                 url_fun()
               )

      assert %{email: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Org, :count) == before_orgs
      refute_email_sent()
    end

    test "rejects an invalid firm before creating its owner" do
      before_users = Repo.aggregate(User, :count)

      assert {:error, changeset} =
               Accounts.provision_firm(
                 %{name: ""},
                 %{name: "No Firm", email: unique_user_email()},
                 url_fun()
               )

      assert %{name: [_message]} = errors_on(changeset)
      assert Repo.aggregate(User, :count) == before_users
      refute_email_sent()
    end

    test "rejects a malformed owner email before creating the firm" do
      before_orgs = Repo.aggregate(Org, :count)

      assert {:error, changeset} =
               Accounts.provision_firm(
                 %{name: "Invalid Email Firm"},
                 %{name: "Invalid Owner", email: "not-an-email"},
                 url_fun()
               )

      assert %{email: [_message]} = errors_on(changeset)
      assert Repo.aggregate(Org, :count) == before_orgs
      refute_email_sent()
    end

    test "returns the usable setup link when email delivery fails" do
      mailer_config = Application.fetch_env!(:nila, Nila.Mailer)
      Application.put_env(:nila, Nila.Mailer, adapter: Nila.TestFailingMailerAdapter)
      on_exit(fn -> Application.put_env(:nila, Nila.Mailer, mailer_config) end)

      assert {:error, {:email_delivery_failed, details, :delivery_failed}} =
               Accounts.provision_firm(
                 %{name: "Manual Link Firm"},
                 %{name: "Manual Owner", email: unique_user_email()},
                 url_fun()
               )

      assert details.membership.role == "owner"
      assert details.invite_url =~ "/users/invite/"
      refute is_nil(Repo.get(User, details.user.id))
      refute is_nil(Repo.get(Membership, details.membership.id))
    end
  end
end
