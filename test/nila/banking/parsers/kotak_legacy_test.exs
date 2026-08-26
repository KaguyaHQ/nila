defmodule Nila.Banking.Parsers.KotakLegacyTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parsers.KotakLegacy

  @statement """
  Period                       01-Apr-24 to 31-Mar-25
  IFSC Code                    KKBK0000469
  Account No.         6411276188
  Statement of Banking Account
  Date Narration Chq/Ref No. Withdrawal (Dr) Deposit (Cr) Balance
  01-Apr-24 OPENING BALANCE ...                                      291,073.45            291,073.45 (Cr)
  02-Apr-24 PAYMENT TO SUPPLIER       IMPS-123456789012       54,000.00                         237,073.45 (Cr)
  09-Apr-24 CUSTOMER RECEIPT          NEFTINW-0824061146                    500,000.00          737,073.45 (Cr)
  A1 Statement Summary
  Total Withdrawal Amount 54,000.00
  """

  test "parses legacy rows and classifies a wide credit by its column" do
    assert {:ok, artifact} = KotakLegacy.parse(@statement)

    assert artifact.bank_code == "kotak"
    assert artifact.account_number_masked == "•••• 6188"
    assert artifact.opening_balance_paise == 29_107_345
    assert artifact.closing_balance_paise == 73_707_345
    assert artifact.total_withdrawal_paise == 5_400_000
    assert artifact.total_deposit_paise == 50_000_000

    [_payment, receipt] = artifact.transactions
    assert receipt["deposit_paise"] == 50_000_000
    assert receipt["narration"] == "CUSTOMER RECEIPT"
  end
end
