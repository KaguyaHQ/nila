defmodule Nila.Banking.Parsers.HdfcV2Test do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parsers.HdfcV2

  @statement """
  Statement From : 01/04/25 TO : 31/03/26
  Account number : 99999962550443
  Date Narration Chq. / Ref No. Value Date Withdrawal Amount Deposit Amount Closing Balance*
  01/04/2025
  UPI-MUTHUKUMAR-OFFICE ADVANCE
  102405015912 01/04/2025 100.00 0.00 999.00
  02/04/2025 CRV POS CARD REFUND 02/04/2025 0.00 2.00 1,001.00
  HDFC BANK LIMITED
  """

  test "parses logical rows and HDFC's inline refund rows" do
    assert {:ok, artifact} = HdfcV2.parse(@statement)

    assert artifact.bank_code == "hdfc"
    assert artifact.account_number_masked == "•••• 0443"
    assert artifact.statement_from == ~D[2025-04-01]
    assert artifact.statement_to == ~D[2026-03-31]
    assert artifact.opening_balance_paise == 109_900
    assert artifact.closing_balance_paise == 100_100
    assert artifact.total_withdrawal_paise == 10_000
    assert artifact.total_deposit_paise == 200

    [payment, refund] = artifact.transactions
    assert payment["reference"] == "102405015912"
    assert refund["narration"] == "CRV POS CARD REFUND"
  end
end
