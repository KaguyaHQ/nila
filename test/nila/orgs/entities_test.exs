defmodule Nila.Orgs.EntitiesTest do
  use Nila.DataCase

  alias Nila.Orgs
  alias Nila.Orgs.Entity
  alias Nila.Repo

  setup do
    org =
      Orgs.create_org!(%{
        name: "Family Workspace",
        legal_name: "Family Workspace",
        gstin: nil
      })

    %{org: org}
  end

  test "creates separate legal entities under one workspace", %{org: org} do
    assert {:ok, caltech} =
             Orgs.create_entity(%{
               org_id: org.id,
               name: "Caltech Refrigeration",
               gstin: "33BPBPK1081A1ZO",
               address_line1: "No 1",
               city: "Chennai",
               state: "Tamil Nadu",
               postal_code: "600001",
               contact_email: "kannancaltech@gmail.com",
               contact_phone: "9962550448",
               bank_account_holder: "Caltech Refrigeration",
               bank_account_number: "1234567890",
               bank_ifsc: "HDFC0001234",
               bank_name: "HDFC Bank",
               invoice_prefix: "",
               invoice_next: 30,
               invoice_padding: 0
             })

    assert {:ok, breezetech} =
             Orgs.create_entity(%{
               org_id: org.id,
               name: "Breezetech Services",
               gstin: "33ABCDE1234F1Z7",
               state: "Tamil Nadu",
               bank_account_number: "9876543210",
               invoice_prefix: "BT-",
               invoice_next: 7,
               invoice_padding: 3
             })

    assert Enum.map(Orgs.list_entities(org.id), & &1.name) == [
             "Breezetech Services",
             "Caltech Refrigeration"
           ]

    assert caltech.org_id == org.id
    assert breezetech.org_id == org.id
  end

  test "validates GSTIN, state, IFSC, and invoice numbering", %{org: org} do
    assert {:error, changeset} =
             Orgs.create_entity(%{
               org_id: org.id,
               name: "Invalid Entity",
               gstin: "bad",
               state: "Atlantis",
               bank_ifsc: "bad-ifsc",
               invoice_next: 0,
               invoice_padding: 13,
               fiscal_year_start_month: 1
             })

    assert "is not a valid GSTIN" in errors_on(changeset).gstin
    assert "has invalid format" in errors_on(changeset).bank_ifsc
    assert "is invalid" in errors_on(changeset).state
    assert "must be greater than 0" in errors_on(changeset).invoice_next
    assert "must be less than or equal to 12" in errors_on(changeset).invoice_padding
    assert "must be equal to 4" in errors_on(changeset).fiscal_year_start_month
  end

  test "stores bank account number encrypted at rest", %{org: org} do
    assert {:ok, entity} =
             Orgs.create_entity(%{
               org_id: org.id,
               name: "Encrypted Bank Entity",
               gstin: "33ABCDE1234F1Z7",
               state: "Tamil Nadu",
               bank_account_number: "account-secret"
             })

    assert Repo.get!(Entity, entity.id).bank_account_number == "account-secret"

    %{rows: [[stored_account_number]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "select bank_account_number from org_entities where id = $1",
        [entity.id]
      )

    refute stored_account_number =~ "account-secret"
  end

  test "formats invoice numbers with the entity sequence and Indian financial year", %{org: org} do
    assert {:ok, entity} =
             Orgs.create_entity(%{
               org_id: org.id,
               name: "Invoice Entity",
               gstin: "33ABCDE1234F1Z7",
               state: "Tamil Nadu",
               invoice_prefix: "",
               invoice_next: 30,
               invoice_padding: 0
             })

    assert Orgs.formatted_invoice_number(entity, ~D[2026-05-28]) == "30/2026-27"

    assert Orgs.formatted_invoice_number(%{entity | invoice_prefix: "BT-", invoice_padding: 3}) ==
             "BT-030/2026-27"

    assert Orgs.formatted_invoice_number(entity, ~D[2026-03-31]) == "30/2025-26"
  end

  describe "assign_next_invoice_number/2" do
    setup %{org: org} do
      {:ok, entity} =
        Orgs.create_entity(%{
          org_id: org.id,
          name: "Numbering Entity",
          gstin: "33ABCDE1234F1Z7",
          state: "Tamil Nadu",
          invoice_prefix: "KM/",
          invoice_next: 142,
          invoice_padding: 4
        })

      %{entity: entity}
    end

    test "consumes the current invoice_next and returns it formatted", %{entity: entity} do
      assert {:ok, "KM/0142/2026-27"} =
               Orgs.assign_next_invoice_number(entity, ~D[2026-05-28])

      reloaded = Repo.get!(Entity, entity.id)
      assert reloaded.invoice_next == 143
    end

    test "sequential calls yield distinct consecutive numbers with no gap", %{entity: entity} do
      assert {:ok, "KM/0142/2026-27"} = Orgs.assign_next_invoice_number(entity, ~D[2026-05-28])
      assert {:ok, "KM/0143/2026-27"} = Orgs.assign_next_invoice_number(entity, ~D[2026-05-28])
      assert {:ok, "KM/0144/2026-27"} = Orgs.assign_next_invoice_number(entity, ~D[2026-05-28])

      assert Repo.get!(Entity, entity.id).invoice_next == 145
    end

    test "accepts an entity_id integer as well as a struct", %{entity: entity} do
      assert {:ok, "KM/0142/2026-27"} =
               Orgs.assign_next_invoice_number(entity.id, ~D[2026-05-28])
    end

    test "returns :entity_not_found when the entity does not exist" do
      assert {:error, :entity_not_found} =
               Orgs.assign_next_invoice_number(-1, ~D[2026-05-28])
    end

    test "concurrent callers on the same entity get distinct sequential numbers", %{
      entity: entity
    } do
      parent = self()
      n = 10

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Orgs.assign_next_invoice_number(entity, ~D[2026-05-28])
          end)
        end

      results = Task.await_many(tasks, 5_000)

      numbers =
        Enum.map(results, fn {:ok, str} ->
          [_prefix, seq_and_fy] = String.split(str, "/", parts: 2)
          {seq, _} = Integer.parse(seq_and_fy)
          seq
        end)

      assert Enum.sort(numbers) == Enum.to_list(142..(142 + n - 1))
      assert Repo.get!(Entity, entity.id).invoice_next == 142 + n
    end
  end
end
