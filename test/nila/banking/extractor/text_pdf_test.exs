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

  test "rejects an unsupported bank" do
    assert {:error, :unsupported_statement} =
             TextPdf.parse_text("Example Bank statement with transactions")
  end
end
