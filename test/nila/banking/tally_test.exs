defmodule Nila.Banking.TallyTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Tally

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

    assert xml =~
             ~r/<REMOTEALTGUID>[a-f0-9]{8}-[a-f0-9]{4}-8[a-f0-9]{3}-8[a-f0-9]{3}-[a-f0-9]{12}<\/REMOTEALTGUID>/

    refute xml =~ "REMOTEID="
    refute xml =~ "<GUID>"
    refute xml =~ "<REFERENCE>"
    refute xml =~ "<VOUCHERNUMBER>"
    assert xml =~ "<LEDGERNAME>Bank Charges</LEDGERNAME>"
    assert xml =~ "<PAYMENTFAVOURING>Bank Charges</PAYMENTFAVOURING>"
    assert xml =~ "<BANKPARTYNAME>Bank Charges</BANKPARTYNAME>"
    assert xml =~ "<AMOUNT>-413.00</AMOUNT>"
    refute xml =~ ~s(<LEDGER NAME="Suspense")

    assert {:ok, repeated_xml} =
             Tally.build_transaction(statement(), transaction, "MY_BANK & CO", "Bank Charges")

    assert remote_alt_guid(xml) == remote_alt_guid(repeated_xml)
  end

  defp remote_alt_guid(xml) do
    [value] = Regex.run(~r/<REMOTEALTGUID>([^<]+)<\/REMOTEALTGUID>/, xml, capture: :all_but_first)
    value
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
