defmodule Nila.ClientsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Integrations

  test "normalizes chase identity and resolves it within the org" do
    org = org_fixture()

    assert {:ok, client} =
             Clients.create_client(%{
               org_id: org.id,
               name: "Ravi Traders",
               type: "company",
               phone: "+91 98765-43210",
               email: " Accounts@Ravi.EXAMPLE ",
               chase_channel: "whatsapp"
             })

    assert client.phone == "919876543210"
    assert client.email == "accounts@ravi.example"
    assert {:ok, ^client} = Clients.get_by_phone(org.id, "98765 43210")
    assert {:ok, ^client} = Clients.get_by_email(org.id, "ACCOUNTS@RAVI.EXAMPLE")
  end

  test "the selected automated channel requires its contact" do
    org = org_fixture()

    assert {:error, whatsapp} =
             Clients.create_client(%{
               org_id: org.id,
               name: "Ravi Traders",
               type: "company",
               chase_channel: "whatsapp"
             })

    assert "is required for WhatsApp chases" in errors_on(whatsapp).phone

    assert {:error, email} =
             Clients.create_client(%{
               org_id: org.id,
               name: "Ravi Traders",
               type: "company",
               chase_channel: "email"
             })

    assert "is required for email chases" in errors_on(email).email
  end

  test "email chase selection requires an active Gmail connector" do
    org = org_fixture()

    attrs = %{
      org_id: org.id,
      name: "Ravi Traders",
      type: "company",
      email: "ravi@example.com",
      chase_channel: "email"
    }

    assert {:error, changeset} = Clients.create_client(attrs)
    assert [message] = errors_on(changeset).chase_channel
    assert message =~ "requires a connected Gmail account"

    assert {:ok, _connection} =
             Integrations.upsert_connection(%{
               org_id: org.id,
               provider: "gmail",
               external_account_id: "firm@example.com",
               credentials: %{"access_token" => "token"}
             })

    assert {:ok, client} = Clients.create_client(attrs)
    assert client.chase_channel == "email"
  end

  test "one phone number cannot identify two clients in the same org" do
    org = org_fixture()

    assert {:ok, _client} =
             Clients.create_client(%{
               org_id: org.id,
               name: "Ravi Traders",
               type: "company",
               phone: "9876543210"
             })

    assert {:error, changeset} =
             Clients.create_client(%{
               org_id: org.id,
               name: "Ravi Industries",
               type: "company",
               phone: "+91 98765 43210"
             })

    assert "has already been taken" in errors_on(changeset).phone
  end
end
