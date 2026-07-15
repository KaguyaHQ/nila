defmodule NilaWeb.BankLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Nila.Banking

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, account} =
      Banking.upsert_account(%{
        org_id: org.id,
        account_number_masked: "4021",
        ifsc: "HDFC0000123",
        bank_name: "HDFC Bank",
        label: "HDFC Current"
      })

    {:ok, _count} =
      Banking.upsert_transactions(account, [
        %{
          "txn_date" => "2026-05-02",
          "value_date" => "2026-05-02",
          "amount" => "12500.00",
          "direction" => "credit",
          "balance" => "112500.00",
          "narration" => "UPI/CR/241023456789/RAMESH KUMAR/HDFC",
          "ref" => "241023456789",
          "mode" => "upi"
        }
      ])

    %{conn: log_in_user(conn, user), org: org, account: account}
  end

  test "lists accounts and streams transactions for the selected one", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, ~p"/bank")

    assert has_element?(view, "#bank-page")
    assert has_element?(view, "#bank-account-#{account.id}")

    {:ok, view, _html} = live(conn, ~p"/bank?#{[account_id: account.id]}")

    [transaction] = Banking.list_transactions(account.id)

    assert has_element?(view, "#bank-transactions")
    assert has_element?(view, "#transactions-#{transaction.id}")
  end

  test "redirects logged-out visitors to log in", %{} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/bank")
  end
end
