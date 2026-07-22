defmodule Nila.RepoTest do
  use Nila.DataCase, async: true

  alias Nila.Clients.Client
  alias Nila.Orgs.Org

  describe "fetch/2" do
    test "returns {:ok, row} when the row exists" do
      client = client_fixture()

      assert {:ok, %Client{id: id}} = Repo.fetch(Client, client.id)
      assert id == client.id
    end

    test "returns {:error, :not_found} when the row is missing" do
      assert Repo.fetch(Client, -1) == {:error, :not_found}
    end
  end

  describe "fetch_one/1" do
    test "returns {:ok, row} when the query returns a row" do
      client = client_fixture()

      query = from c in Client, where: c.id == ^client.id

      assert {:ok, %Client{id: id}} = Repo.fetch_one(query)
      assert id == client.id
    end

    test "returns {:error, :not_found} when the query returns nil" do
      query = from c in Client, where: c.id == -1

      assert Repo.fetch_one(query) == {:error, :not_found}
    end
  end

  describe "fetch_by/2" do
    test "returns {:ok, row} when matching clauses find a row" do
      client = client_fixture(%{name: "Fetch By Co"})

      assert {:ok, %Client{id: id}} =
               Repo.fetch_by(Client, org_id: client.org_id, name: "Fetch By Co")

      assert id == client.id
    end

    test "returns {:error, :not_found} when matching clauses find no row" do
      assert Repo.fetch_by(Client, name: "missing-client") == {:error, :not_found}
    end
  end

  defp client_fixture(attrs \\ %{}) do
    org =
      %Org{}
      |> Org.changeset(%{
        name: "Repo Test #{System.unique_integer([:positive])}",
        legal_name: "Repo Test Company"
      })
      |> Repo.insert!()

    attrs =
      Map.merge(
        %{
          org_id: org.id,
          name: "Repo Client #{System.unique_integer([:positive])}",
          type: "company"
        },
        attrs
      )

    %Client{}
    |> Client.changeset(attrs)
    |> Repo.insert!()
  end
end
