defmodule Nila.Banking.Extractor.TextPdfTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Extractor.TextPdf

  test "detects HDFC from statement text" do
    text = """
    HDFC BANK LIMITED
    Account No : 00000000004587 OTHER
    Date Narration Chq./Ref.No. Value Dt Withdrawal Amt. Deposit Amt. Closing Balance
    08/08/24 OPENING CAPITAL 0000000000000003 08/08/24 0.00 500,000.00 500,000.00
    """

    assert {:ok, artifact} = TextPdf.parse_text(text)
    assert artifact.bank_code == "hdfc"
  end

  test "detects Kotak from statement text" do
    text = """
    Account Statement
    Account No. 0054127036
    Kotak Mahindra Bank Ltd.
    Savings Account Transactions
    # Date Description Chq/Ref. No. Withdrawal (Dr.) Deposit (Cr.) Balance
    - - Opening Balance - - - 1,519.74
    1 04 Jun 2026 CARD PAYMENT 615572081464 528.73 991.01
    """

    assert {:ok, artifact} = TextPdf.parse_text(text)
    assert artifact.bank_code == "kotak"
  end

  test "detects IOB from statement text" do
    text = """
    Account Number : 236402000000087
    IFSC Code : IOBA0002364
    Statement for the period from 01-04-2025 00:00:00 to 31-03-2026 23:59:59
    Date Value Date CHQ Remarks COD Debit Credit Balance
    02/04/2025 01/04/2025 NEFT-DEUT-DEUTH01509100260-
                                  TRF               22,280.00 7,702,273.76
    """

    assert {:ok, artifact} = TextPdf.parse_text(text)
    assert artifact.bank_code == "iob"
  end

  test "rejects an unsupported bank" do
    assert {:error, :unsupported_statement} =
             TextPdf.parse_text("Example Bank statement with transactions")
  end

  test "does not fall through after a recognized parser rejects the accounting" do
    text = """
    HDFC BANK LIMITED
    Account No : 00000000004587 OTHER
    Date Narration Chq./Ref.No. Value Dt Withdrawal Amt. Deposit Amt. Closing Balance
    08/08/24 OPENING CAPITAL 0000000000000003 08/08/24 0.00 500,000.00 500,000.00
    09/08/24 PAYMENT 0000000000000004 09/08/24 100.00 0.00 499,999.00
    Kotak Mahindra Bank Withdrawal (Dr.) Deposit (Cr.)
    """

    assert {:error, {:statement_does_not_tally, 2, 49_990_000, 49_999_900}} =
             TextPdf.parse_text(text)
  end
end
