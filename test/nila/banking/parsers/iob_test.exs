defmodule Nila.Banking.Parsers.IobTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parsers.Iob

  @statement """
  Account Number : 236402000000087 Branch Name : PADI (2364)
  IFSC Code : IOBA0002364
  Statement for the period from 01-04-2025 00:00:00 to 31-03-2026 23:59:59
  Date Value Date CHQ Remarks COD Debit Credit Balance

  24/03/2026 24/03/2026 NEFT-DEUT-DEUTH00608312890-
                                      TRF               32,649.00 287,723.44
                          SIEMENS HE-120202526

  Date and Time:
  15/08/2026 05:43:25 PM IST Page 1 of 6
  13/03/2026 13/03/2026 ITAX-130326-NET@713130 TRF 100,000.00                    255,074.44

  02/04/2025 01/04/2025 NEFT-DEUT-DEUTH01509100260-
                                      TRF               22,280.00 355,074.44
                          ELEKTA MED-475 800000
                            100,000.00 54,929.00
  """

  test "parses newest-first IOB rows into reconciled ledger order" do
    assert {:ok, artifact} = Iob.parse(@statement)

    assert artifact.bank_code == "iob"
    assert artifact.account_number_masked == "•••• 0087"
    assert artifact.statement_from == ~D[2025-04-01]
    assert artifact.statement_to == ~D[2026-03-31]
    assert artifact.opening_balance_paise == 33_279_444
    assert artifact.closing_balance_paise == 28_772_344
    assert artifact.total_withdrawal_paise == 10_000_000
    assert artifact.total_deposit_paise == 5_492_900

    [credit, debit, latest_credit] = artifact.transactions
    assert credit["date"] == ~D[2025-04-02]
    assert credit["narration"] == "NEFT-DEUT-DEUTH01509100260- ELEKTA MED-475 800000"
    assert debit["withdrawal_paise"] == 10_000_000
    assert latest_credit["deposit_paise"] == 3_264_900
  end

  test "rejects another bank's text" do
    assert {:error, :unsupported_statement} = Iob.parse("Example Bank statement")
  end
end
