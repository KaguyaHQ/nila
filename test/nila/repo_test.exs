defmodule Nila.RepoTest do
  use Nila.DataCase, async: true

  alias Nila.Documents.Document
  alias Nila.Orgs.Org

  describe "fetch/2" do
    test "returns {:ok, row} when the row exists" do
      document = document_fixture()

      assert {:ok, %Document{id: id}} = Repo.fetch(Document, document.id)
      assert id == document.id
    end

    test "returns {:error, :not_found} when the row is missing" do
      assert Repo.fetch(Document, -1) == {:error, :not_found}
    end
  end

  describe "fetch_one/1" do
    test "returns {:ok, row} when the query returns a row" do
      document = document_fixture()

      query = from d in Document, where: d.id == ^document.id

      assert {:ok, %Document{id: id}} = Repo.fetch_one(query)
      assert id == document.id
    end

    test "returns {:error, :not_found} when the query returns nil" do
      query = from d in Document, where: d.id == -1

      assert Repo.fetch_one(query) == {:error, :not_found}
    end
  end

  describe "fetch_by/2" do
    test "returns {:ok, row} when matching clauses find a row" do
      document = document_fixture(%{filename: "fetch-by.pdf"})

      assert {:ok, %Document{id: id}} =
               Repo.fetch_by(Document, org_id: document.org_id, filename: "fetch-by.pdf")

      assert id == document.id
    end

    test "returns {:error, :not_found} when matching clauses find no row" do
      assert Repo.fetch_by(Document, filename: "missing.pdf") == {:error, :not_found}
    end
  end

  defp document_fixture(attrs \\ %{}) do
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
          storage_key: "test/#{System.unique_integer([:positive])}",
          filename: "repo-#{System.unique_integer([:positive])}.pdf",
          byte_size: 1024,
          status: "uploaded"
        },
        attrs
      )

    %Document{}
    |> Document.changeset(attrs)
    |> Repo.insert!()
  end
end
