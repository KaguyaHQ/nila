defmodule Nila.Banking.TransactionGroupingTest do
  use ExUnit.Case, async: true

  alias Nila.Banking.Transaction
  alias Nila.Banking.TransactionGrouping

  test "groups only transactions with the same UPI identity, direction, and stable pattern" do
    purchase_one =
      transaction(
        1,
        "UPI-MUTHUKUMAR M-MK18248883@OKHDFCBANK-HDFC0001254-102475830728-COMPRESSOR PURCHASE",
        3_800
      )

    purchase_two =
      transaction(
        2,
        "UPI-MUTHUKUMAR M-MK18248883@OKHDFCBANK-HDFC0001254-102497600646-COMPRESSOR PURCHASE",
        4_200
      )

    salary =
      transaction(
        3,
        "UPI-MUTHUKUMAR M-MK18248883@OKHDFCBANK-HDFC0001254-102497600647-SALARY TO MUTHUK UM",
        25_260
      )

    spares =
      transaction(
        4,
        "UPI-MUTHUKUMAR M-MK18248883@OKHDFCBANK-HDFC0001254-102497600648-COMPRESSOR SPARES",
        3_400
      )

    other_payee =
      transaction(
        5,
        "UPI-RAJA G-GRAJA19122001@OKHDFCBANK-TMBL0000093-102497530491-COMPRESSOR PURCHASE",
        3_000
      )

    assert %{groups: [group], individuals: individuals} =
             TransactionGrouping.group([
               purchase_one,
               purchase_two,
               salary,
               spares,
               other_payee
             ])

    assert group.payee == "Muthukumar M"
    assert group.pattern == "COMPRESSOR PURCHASE"
    assert group.match_basis == "Same payee and payment pattern"
    assert group.transaction_type == "payment"
    assert group.count == 2
    assert group.total_paise == 8_000
    assert group.transactions == [purchase_one, purchase_two]
    assert Enum.map(individuals, & &1.id) == [salary.id, spares.id, other_payee.id]
  end

  test "does not group a matching narration across payment directions" do
    payment = transaction(1, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830728-SERVICE", 1_000)

    receipt = %{
      transaction(2, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830729-SERVICE", 0)
      | transaction_type: "receipt",
        withdrawal_paise: 0,
        deposit_paise: 1_000
    }

    assert %{groups: [], individuals: [^payment, ^receipt]} =
             TransactionGrouping.group([payment, receipt])
  end

  test "keeps narrations without a meaningful residual pattern individual" do
    first = transaction(1, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830728", 1_000)
    second = transaction(2, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830729", 1_000)

    assert %{groups: [], individuals: [^first, ^second]} =
             TransactionGrouping.group([first, second])
  end

  test "does not treat an empty bank memo as evidence of one accounting decision" do
    first = transaction(1, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830728-NA", 1_000)
    second = transaction(2, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830729-NA", 1_000)

    assert %{groups: [], individuals: [^first, ^second]} =
             TransactionGrouping.group([first, second])
  end

  test "does not merge different payees whose short UPI handles happen to match" do
    first = transaction(1, "UPI-VENDOR A-ONE-1@OKSBI-ABCD0001234-102475830728-PURCHASE", 1_000)

    second =
      transaction(2, "UPI-VENDOR B-TWO-1@OKSBI-ABCD0001234-102475830729-PURCHASE", 1_000)

    assert %{groups: [], individuals: [^first, ^second]} =
             TransactionGrouping.group([first, second])
  end

  test "groups deterministic bank charges and interest despite changing dates and references" do
    markup_one = transaction(1, ".DC INTL POS TXN MARKUP+ST 210325 210325 -MIR2609583159237", 71)
    markup_two = transaction(2, "DC INTL POS TXN MARKUP+ST 210226-EPR2606022169076", 75)

    interest_one =
      %{transaction(3, "INTEREST PAID TILL 30-JUN-2025", 0) | transaction_type: "receipt"}

    interest_two =
      %{transaction(4, "INTEREST PAID TILL 30-SEP-2025", 0) | transaction_type: "receipt"}

    assert %{groups: [markup, interest], individuals: []} =
             TransactionGrouping.group([markup_one, markup_two, interest_one, interest_two])

    assert {markup.payee, markup.match_basis, markup.count} ==
             {"Bank charges", "Same bank charge", 2}

    assert {interest.payee, interest.match_basis, interest.count} ==
             {"Bank interest", "Same bank credit", 2}
  end

  test "groups recurring card merchants by the same card and merchant" do
    first =
      transaction(1, "ME DC SI 416021XXXXXX5696 ACME SOFTWARE SUBSCR", 1_760)

    second =
      transaction(2, "ME DC SI 416021XXXXXX5696 ACME SOFTWARE SUBSCRIPTION", 1_775)

    other_merchant = transaction(3, "ME DC SI 416021XXXXXX5696 OTHER SOFTWARE", 8_000)

    assert %{groups: [group], individuals: [^other_merchant]} =
             TransactionGrouping.group([first, second, other_merchant])

    assert group.payee == "Acme Software"
    assert group.match_basis == "Same card and merchant"
  end

  test "groups POS and card-debit formats when the card and merchant are identical" do
    first = transaction(1, "ME DC SI 403875XXXXXX0261 ACME CLOUD", 1_000)
    second = transaction(2, "POS 403875XXXXXX0261 ACME CLOUD", 1_100)

    assert %{groups: [group], individuals: []} = TransactionGrouping.group([first, second])
    assert {group.payee, group.count} == {"Acme Cloud", 2}
  end

  test "removes generic POS metadata without knowing the merchant" do
    recurring = transaction(1, "ME DC SI 403875XXXXXX0261 ACME CLOUD SUBSCRIPTION", 1_000)

    noisy =
      transaction(
        2,
        "POS 403875XXXXXX0261 609717478239 07APR26 22:38:10 +14152360599 ACME CLOUD SUBSCR",
        1_100
      )

    assert %{groups: [group], individuals: []} =
             TransactionGrouping.group([recurring, noisy])

    assert group.payee == "Acme Cloud"
  end

  test "groups DCC, debit-card, and AQB charges as bank charges" do
    dcc = transaction(1, ".DC INTL POS TXN DCC+ST 081025 081025-CDT2531037111997", 100)
    debit_card = transaction(2, "POS DECCHG 31/01/26 CARDEND", 200)
    aqb = transaction(3, "AQB SER CHGS INC GST MAR26-EPR2709624097224", 300)

    assert %{groups: [group], individuals: []} =
             TransactionGrouping.group([dcc, debit_card, aqb])

    assert {group.payee, group.count, group.total_paise} == {"Bank charges", 3, 600}
  end

  test "groups exact HDFC TPT details while retaining the account and purpose" do
    first = transaction(1, "50100747794209-TPT-SALARY-PRASHANT THAPA", 1_000)
    second = transaction(2, "50100747794209-TPT-SALARY-PRASHANT THAPA", 1_100)
    other_purpose = transaction(3, "50100747794209-TPT-CURSOR AUG-PRASHANT THAPA", 1_200)

    assert %{groups: [group], individuals: [^other_purpose]} =
             TransactionGrouping.group([first, second, other_purpose])

    assert {group.payee, group.pattern, group.match_basis} ==
             {"Prashant Thapa", "SALARY", "Same bank transfer details"}
  end

  test "groups exact NEFT, bill-pay, and IMPS structures after removing bank references" do
    neft_one =
      transaction(
        1,
        "NEFT CR-IOBA0002364-BREEZE TECH-HEMALATH A-IOBAN22025041059029829",
        1_000
      )

    neft_two =
      transaction(
        2,
        "NEFT CR-IOBA0002364-BREEZE TECH-HEMALATH A-IOBAN22025050165042506",
        2_000
      )

    billpay_one = transaction(3, "IB BILLPAY DR-HDFCEA-553583XXXXXX7300 1762516630539296", 500)
    billpay_two = transaction(4, "IB BILLPAY DR-HDFCEA-553583XXXXXX7300 1763805483615762", 600)

    imps_one =
      transaction(5, "IMPS-518311555067-BREEZE TECH-IOBA-XXXXXXXXXXX0127-TRANSFER", 1_500)

    imps_two =
      transaction(6, "IMPS-520012429460-BREEZE TECH-IOBA-XXXXXXXXXXX0127-TRANSFER", 1_800)

    assert %{groups: groups, individuals: []} =
             TransactionGrouping.group([
               neft_one,
               neft_two,
               billpay_one,
               billpay_two,
               imps_one,
               imps_two
             ])

    assert Enum.map(groups, &{&1.payee, &1.match_basis}) == [
             {"Breeze Tech", "Same NEFT details"},
             {"Bill payment · ••••7300", "Same bill-pay account"},
             {"Breeze Tech", "Same beneficiary and payment details"}
           ]
  end

  test "groups NEFT details across changing bank reference formats" do
    first =
      transaction(
        1,
        "NEFT DR-SBIN0070314-P GAYATHRI-NETBANK, MUM-N248243244675336-SALARY",
        1_000
      )

    second =
      transaction(
        2,
        "NEFT DR-SBIN0070314-P GAYATHRI-NETBANK, MUM-HDFCN52025020441154894-SALARY",
        1_100
      )

    assert %{groups: [group], individuals: []} = TransactionGrouping.group([first, second])
    assert group.payee == "P Gayathri"
    assert group.pattern == "NETBANK, MUM · SALARY"
  end

  defp transaction(id, narration, amount) do
    %Transaction{
      id: id,
      ordinal: id,
      narration: narration,
      transaction_type: "payment",
      withdrawal_paise: amount,
      deposit_paise: 0
    }
  end
end
