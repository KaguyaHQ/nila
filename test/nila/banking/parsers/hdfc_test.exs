defmodule Nila.Banking.Parsers.HdfcTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parsers.Hdfc

  @statement """
  HDFC BANK LIMITED
  Account No     : 00000000004587 OTHER
      Date                                     Narration                                          Chq./Ref.No.             Value Dt        Withdrawal Amt.                 Deposit Amt.              Closing Balance
   08/08/24      OPENING CAPITAL                                                           0000000000000003           08/08/24                          0.00                500,000.00                   500,000.00
   29/08/24      DEBIT CARD ISSUANCE FEE                                                   MIR2524292468307             29/08/24                       413.00                         0.00                 499,587.00
                 090824-MIR2524292468307
   31/08/24      TEST CREDIT                                                               HSBCN24244092685              31/08/24                          0.00                        1.00                 499,588.00
  """

  test "parses wrapped HDFC rows and proves the running balance" do
    assert {:ok, artifact} = Hdfc.parse(@statement)

    assert artifact.account_number_masked == "•••• 4587"
    assert artifact.statement_from == ~D[2024-08-08]
    assert artifact.statement_to == ~D[2024-08-31]
    assert artifact.opening_balance_paise == 0
    assert artifact.closing_balance_paise == 49_958_800
    assert artifact.total_withdrawal_paise == 41_300
    assert artifact.total_deposit_paise == 50_000_100
    assert length(artifact.transactions) == 3

    fee = Enum.at(artifact.transactions, 1)
    assert fee["narration"] == "DEBIT CARD ISSUANCE FEE 090824-MIR2524292468307"
    assert fee["reference"] == "MIR2524292468307"
  end

  test "rejects a row whose printed closing balance does not tally" do
    broken = String.replace(@statement, "499,588.00", "499,589.00")
    assert {:error, {:statement_does_not_tally, 3, _, _}} = Hdfc.parse(broken)
  end
end
