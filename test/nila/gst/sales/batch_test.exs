defmodule Nila.Gst.Sales.BatchTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Sales.Batch

  test "the same import reference is unique within a client, not across the firm" do
    %{org: org} = user_with_org_fixture()
    {:ok, first_client} = Clients.create_client(%{org_id: org.id, name: "First", type: "company"})

    {:ok, second_client} =
      Clients.create_client(%{org_id: org.id, name: "Second", type: "company"})

    import_ref = "shared-upstream-reference"

    assert {:ok, _first} = Batch.create(org.id, first_client.id, import_ref)
    assert {:ok, _second} = Batch.create(org.id, second_client.id, import_ref)
    assert {:error, changeset} = Batch.create(org.id, first_client.id, import_ref)
    assert "has already been taken" in errors_on(changeset).import_ref
  end
end
