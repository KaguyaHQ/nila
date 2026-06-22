defmodule Nila.BankingTest do
  use Nila.DataCase

  alias Nila.Banking
  alias Nila.Banking.Transaction
  alias Nila.Orgs
  alias Nila.Repo

  setup do
    org =
      Orgs.create_org!(%{
        name: "Banking Test Co",
        legal_name: "Banking Test Company",
        gstin: "29ABCDE1234F1ZW"
      })

    entity = Orgs.get_or_create_default_entity!(org.id)

    {:ok, account} =
      Banking.upsert_account(%{
        org_id: org.id,
        entity_id: entity.id,
        account_number_masked: "4021",
        ifsc: "HDFC0000123",
        bank_name: "HDFC Bank",
        label: "HDFC Current"
      })

    %{org: org, entity: entity, account: account}
  end

  defp lines do
    [
      %{
        "txn_date" => "2026-05-02",
        "value_date" => "2026-05-02",
        "amount" => "12500.00",
        "direction" => "credit",
        "balance" => "112500.00",
        "narration" => "UPI/CR/241023456789/RAMESH KUMAR/HDFC",
        "ref" => "241023456789",
        "mode" => "upi"
      },
      %{
        "txn_date" => "2026-05-12",
        "value_date" => "2026-05-12",
        "amount" => "60000.00",
        "direction" => "debit",
        "balance" => "87150.00",
        "narration" => "NEFT DR-ICIC0000456-SUPPLIER STEEL WORKS",
        "ref" => "ICIC26051298765",
        "mode" => "neft"
      }
    ]
  end

  test "upsert_account is idempotent on the natural key", %{
    org: org,
    entity: entity,
    account: account
  } do
    {:ok, again} =
      Banking.upsert_account(%{
        org_id: org.id,
        entity_id: entity.id,
        account_number_masked: "4021",
        ifsc: "HDFC0000123",
        bank_name: "HDFC Bank Ltd",
        label: "HDFC Current"
      })

    assert again.id == account.id
    assert Repo.aggregate(Banking.Account, :count) == 1
  end

  test "upsert_transactions projects rows with positive amount and explicit direction", %{
    account: account
  } do
    assert {:ok, 2} = Banking.upsert_transactions(account, lines())

    transactions = Banking.list_transactions(account.id)
    assert length(transactions) == 2

    credit = Enum.find(transactions, &(&1.direction == "credit"))
    assert Decimal.equal?(credit.amount, Decimal.new("12500.00"))
    assert credit.mode == "upi"
    assert credit.txn_id
  end

  test "re-importing the same statement yields no duplicate transactions", %{account: account} do
    assert {:ok, 2} = Banking.upsert_transactions(account, lines())
    assert {:ok, 2} = Banking.upsert_transactions(account, lines())

    assert Banking.count_transactions(account.id) == 2
    assert Repo.aggregate(Transaction, :count) == 2
  end

  test "overlapping re-import only inserts the new line", %{account: account} do
    assert {:ok, 2} = Banking.upsert_transactions(account, lines())

    extra =
      lines() ++
        [
          %{
            "txn_date" => "2026-05-20",
            "value_date" => "2026-05-20",
            "amount" => "5000.00",
            "direction" => "credit",
            "balance" => "92150.00",
            "narration" => "UPI/CR/999/NEW PAYER",
            "ref" => "999",
            "mode" => "upi"
          }
        ]

    assert {:ok, 3} = Banking.upsert_transactions(account, extra)
    assert Banking.count_transactions(account.id) == 3
  end
end
