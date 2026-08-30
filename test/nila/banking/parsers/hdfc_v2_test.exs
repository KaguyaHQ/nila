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

  test "rejoins words split at HDFC's fixed narration width" do
    statement = """
    Statement From : 01/04/25 TO : 31/03/26
    Account number : 99999962550443
    Date Narration Chq. / Ref No. Value Date Withdrawal Amount Deposit Amount Closing Balance*
    21/04/2025
    ME DC SI 416021XXXXXX5696 OPENAI *CHATGP
    T SUBSCR
    511111838489 21/04/2025 1,710.60 0.00 2,95,766.45
    22/04/2025
    DEBIT CARD ISSUANCE FEE
    090824-MIR2524292468307
    MIR2524292468307 22/04/2025 413.00 0.00 2,95,353.45
    HDFC BANK LIMITED
    """

    assert {:ok, artifact} = HdfcV2.parse(statement)
    assert [transaction, ordinary_wrap] = artifact.transactions

    assert transaction["narration"] ==
             "ME DC SI 416021XXXXXX5696 OPENAI *CHATGPT SUBSCR"

    assert ordinary_wrap["narration"] ==
             "DEBIT CARD ISSUANCE FEE 090824-MIR2524292468307"
  end
end
