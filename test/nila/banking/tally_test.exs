defmodule Nila.Banking.TallyTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Tally

  test "builds balanced Payment and Receipt vouchers with bank allocations" do
    assert {:ok, xml} = Tally.build(statement())

    assert xml =~ "<REPORTNAME>All Masters</REPORTNAME>"
    assert xml =~ ~s(<LEDGER NAME="Suspense" ACTION="Create">)
    assert xml =~ ~s(VCHTYPE="Payment" ACTION="Create")
    assert xml =~ ~s(VCHTYPE="Receipt" ACTION="Create")
    assert xml =~ "<LEDGERNAME>MY_BANK &amp; CO</LEDGERNAME>"
    assert xml =~ "<NARRATION>Fee &amp; tax</NARRATION>"
    assert xml =~ "<INSTRUMENTNUMBER>REF-1</INSTRUMENTNUMBER>"
    assert xml =~ "<AMOUNT>-413.00</AMOUNT>"
    assert xml =~ "<AMOUNT>413.00</AMOUNT>"
    assert xml =~ "<AMOUNT>500000.00</AMOUNT>"
    assert xml =~ "<AMOUNT>-500000.00</AMOUNT>"
  end

  test "filters vouchers to the requested inclusive date range" do
    assert {:ok, xml} = Tally.build(statement(), from: ~D[2026-06-02], to: ~D[2026-06-02])
    refute xml =~ "Fee &amp; tax"
    assert xml =~ "Capital"

    assert {:error, :no_transactions} =
             Tally.build(statement(), from: ~D[2026-07-01], to: ~D[2026-07-31])
  end

  test "keeps remote ids stable across repeated downloads" do
    assert {:ok, first} = Tally.build(statement())
    assert {:ok, second} = Tally.build(statement())
    assert Regex.scan(~r/REMOTEID="([^"]+)"/, first) == Regex.scan(~r/REMOTEID="([^"]+)"/, second)
  end

  test "removes characters XML 1.0 cannot represent" do
    statement =
      put_in(statement(), [:transactions, Access.at(0), "narration"], "Fee\u0000 and tax")

    assert {:ok, xml} = Tally.build(statement)
    assert xml =~ "<NARRATION>Fee and tax</NARRATION>"
    refute xml =~ "\u0000"
  end

  test "builds one mapped connector voucher without creating Suspense" do
    transaction = %{
      identity: "bank-row-1",
      ordinal: 1,
      date: ~D[2026-06-01],
      narration: "Bank fee",
      reference: "REF-1",
      withdrawal_paise: 41_300,
      deposit_paise: 0,
      transaction_type: "payment"
    }

    assert {:ok, xml} =
             Tally.build_transaction(statement(), transaction, "MY_BANK & CO", "Bank Charges")

    assert xml =~ "<VOUCHERTYPENAME>Payment</VOUCHERTYPENAME>"
    assert xml =~ "<TALLYREQUEST>Import</TALLYREQUEST>"
    assert xml =~ "<TYPE>Data</TYPE><ID>Vouchers</ID>"
    assert xml =~ "<SVCURRENTCOMPANY>Nila</SVCURRENTCOMPANY>"
    assert xml =~ "<LEDGERNAME>Bank Charges</LEDGERNAME>"
    assert xml =~ "<AMOUNT>-413.00</AMOUNT>"
    refute xml =~ ~s(<LEDGER NAME="Suspense")
  end

  defp statement do
    %{
      id: 42,
      status: "ready",
      source_key: "statement.pdf",
      tally_company: %{name: "Nila"},
      bank_ledger_name: "MY_BANK & CO",
      statement_from: ~D[2026-06-01],
      statement_to: ~D[2026-06-02],
      transactions: [
        %{
          "id" => "one",
          "ordinal" => 1,
          "date" => "2026-06-01",
          "narration" => "Fee & tax",
          "reference" => "REF-1",
          "withdrawal_paise" => 41_300,
          "deposit_paise" => 0,
          "balance_paise" => 9_958_700
        },
        %{
          "id" => "two",
          "ordinal" => 2,
          "date" => "2026-06-02",
          "narration" => "Capital",
          "reference" => "REF-2",
          "withdrawal_paise" => 0,
          "deposit_paise" => 50_000_000,
          "balance_paise" => 59_958_700
        }
      ]
    }
  end
end
