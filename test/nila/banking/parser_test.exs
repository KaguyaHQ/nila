defmodule Nila.Banking.ParserTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parser

  @metadata %{
    bank_code: "test",
    account_number_masked: "•••• 1234",
    statement_from: ~D[2025-04-01],
    statement_to: ~D[2025-04-30],
    opening_balance_paise: 100_000,
    meta: %{"parser" => "test_v1"}
  }

  test "orders newest-first rows and builds a reconciled artifact" do
    rows = [
      row(~D[2025-04-03], 0, 20_000, 115_000),
      row(~D[2025-04-02], 5_000, 0, 95_000)
    ]

    assert {:ok, artifact} = Parser.finalize(@metadata, rows, order: :newest_first)

    assert Enum.map(artifact.transactions, & &1["date"]) == [~D[2025-04-02], ~D[2025-04-03]]
    assert artifact.total_withdrawal_paise == 5_000
    assert artifact.total_deposit_paise == 20_000
    assert Enum.map(artifact.transactions, & &1["ordinal"]) == [1, 2]

    assert hd(artifact.transactions)["id"] ==
             "e0ddbd21e2d6801399edf095f05313a6faa56801fa21c493a2179698b4cc4c75"
  end

  test "infers an ambiguous amount from the printed running balance" do
    rows = [
      row(~D[2025-04-02], nil, nil, 95_000) |> Map.put("amount_paise", 5_000),
      row(~D[2025-04-03], nil, nil, 115_000) |> Map.put("amount_paise", 20_000)
    ]

    assert {:ok, artifact} = Parser.finalize(@metadata, rows)
    assert [debit, credit] = artifact.transactions
    assert {debit["withdrawal_paise"], debit["deposit_paise"]} == {5_000, 0}
    assert {credit["withdrawal_paise"], credit["deposit_paise"]} == {0, 20_000}
  end

  test "rejects a row that does not prove against the running balance" do
    rows = [row(~D[2025-04-02], 5_000, 0, 96_000)]

    assert {:error, {:statement_does_not_tally, 1, 95_000, 96_000}} =
             Parser.finalize(@metadata, rows)
  end

  test "derives the opening balance when the statement does not print one" do
    metadata = Map.delete(@metadata, :opening_balance_paise)
    rows = [row(~D[2025-04-02], 5_000, 0, 95_000)]

    assert {:ok, artifact} = Parser.finalize(metadata, rows)
    assert artifact.opening_balance_paise == 100_000
  end

  defp row(date, withdrawal, deposit, balance) do
    %{
      "date" => date,
      "value_date" => date,
      "narration" => "TEST",
      "reference" => nil,
      "withdrawal_paise" => withdrawal,
      "deposit_paise" => deposit,
      "balance_paise" => balance
    }
  end
end
