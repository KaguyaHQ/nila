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

  test "does not present generic bank filler as a shared payment pattern" do
    first = transaction(1, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830728-NA", 1_000)
    second = transaction(2, "UPI-VENDOR-VENDOR@OKBANK-ABCD0001234-102475830729-NA", 1_000)

    assert %{groups: [], individuals: [^first, ^second]} =
             TransactionGrouping.group([first, second])
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
