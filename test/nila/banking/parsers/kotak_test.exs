defmodule Nila.Banking.Parsers.KotakTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Parsers.Kotak

  @statement """
  Account Statement
  Account No. 0054127036
  Kotak Mahindra Bank Ltd.
  Savings Account Transactions
      #       Date           Description                                  Chq/Ref. No.    Withdrawal (Dr.)     Deposit (Cr.)       Balance
  -       -                 Opening Balance                           -                                    -                   -             1,519.74
  1           04 Jun 2026   CARD PAYMENT                              615572081464                      528.73                                   991.01
                            CONTINUED DETAIL
  2           05 Jun 2026   UPI/VASANTH                               UPI-615612757894                                 2,500.00              3,491.01
  """

  test "parses Kotak amount columns and wrapped narration" do
    assert {:ok, artifact} = Kotak.parse(@statement)

    assert artifact.bank_code == "kotak"
    assert artifact.account_number_masked == "•••• 7036"
    assert artifact.opening_balance_paise == 151_974
    assert artifact.closing_balance_paise == 349_101
    assert artifact.total_withdrawal_paise == 52_873
    assert artifact.total_deposit_paise == 250_000
    assert length(artifact.transactions) == 2

    [card, credit] = artifact.transactions
    assert card["narration"] == "CARD PAYMENT CONTINUED DETAIL"
    assert card["reference"] == "615572081464"
    assert credit["reference"] == "UPI-615612757894"
  end

  test "classifies a wide credit by its distance from the balance column" do
    statement = """
    Account Statement
    Account No. 5556555511
    Kotak Mahindra Bank Ltd.
    Current Account Transactions
    # Date Description Chq/Ref. No. Withdrawal (Dr.) Deposit (Cr.) Balance
    - - Opening Balance - - - 2,44,345.64
    122     16 Oct 2025   NEFT IOBAN25289074643 BREEZE TECH       NEFTINW-1367738637                 5,00,000.00   7,44,345.64
    """

    assert {:ok, artifact} = Kotak.parse(statement)
    assert [transaction] = artifact.transactions
    assert transaction["deposit_paise"] == 50_000_000
  end

  test "parses Kotak's newer combined signed-amount layout newest-first" do
    statement = """
    Account Statement                                                         Account # 0054127036 SAVINGS
    23 Apr 2026 - 27 Aug 2026
    IFSC KKBK0008488
     #   TRANSACTION DATE       VALUE DATE    TRANSACTION DETAILS                CHQ / REF NO.      DEBIT/CREDIT(₹)     BALANCE(₹)
     1   26 Aug 2026            26 Aug 2026   UPI/Zomato/HDFC/178239359430/UP UPI-623886520805              -603.48           125.17
         04:22 PM                             IIntent
     2   24 Aug 2026            24 Aug 2026   UPI/GST                            UPI-623636885337             -20.00           728.65
         01:11 PM                             payments/HDFC/367961941537/Pay
    """

    assert {:ok, artifact} = Kotak.parse(statement)
    assert artifact.account_number_masked == "•••• 7036"
    assert artifact.statement_from == ~D[2026-04-23]
    assert artifact.statement_to == ~D[2026-08-27]
    assert artifact.opening_balance_paise == 74_865
    assert artifact.closing_balance_paise == 12_517
    assert artifact.total_withdrawal_paise == 62_348
    assert artifact.total_deposit_paise == 0

    [gst, zomato] = artifact.transactions
    assert gst["date"] == ~D[2026-08-24]
    assert zomato["narration"] == "UPI/Zomato/HDFC/178239359430/UP IIntent"
    assert zomato["reference"] == "UPI-623886520805"
  end

  test "parses Kotak's newer split signed-amount layout through the same row path" do
    statement = """
    Account Statement                                                     Account # 0054127036 SAVINGS
    23 Apr 2026 - 27 Aug 2026
    IFSC KKBK0008488
     #    TRANSACTION      TRANSACTION DETAILS                    CHQ / REF NO.          DEBIT(₹)      CREDIT(₹)     BALANCE(₹)
     1    26 Aug 2026      UPI/Zomato/HDFC/178239359430/UPIInten UPI-623886520805         -603.48                          125.17
          04:22 PM         t
     2    24 Aug 2026      UPI/GST                                UPI-623636885337          -20.00                         728.65
          01:11 PM         payments/HDFC/367961941537/Pay
    """

    assert {:ok, artifact} = Kotak.parse(statement)
    assert artifact.opening_balance_paise == 74_865
    assert artifact.closing_balance_paise == 12_517
    assert artifact.total_withdrawal_paise == 62_348
    assert artifact.total_deposit_paise == 0

    [_gst, zomato] = artifact.transactions
    assert zomato["narration"] == "UPI/Zomato/HDFC/178239359430/UPIInten t"
    assert zomato["reference"] == "UPI-623886520805"
  end
end
