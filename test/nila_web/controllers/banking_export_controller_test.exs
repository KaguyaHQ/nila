defmodule NilaWeb.BankingExportControllerTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Storage

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, statement} =
      Banking.record_statement(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{
          source_key: "orgs/#{org.id}/bank-statements/export/original.pdf",
          original_filename: "statement.pdf"
        }
      )

    {:ok, _stored} = Storage.put(statement.source_key, "%PDF", content_type: "application/pdf")
    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})

    %{conn: log_in_user(conn, user), statement: statement}
  end

  test "downloads tenant-scoped bank vouchers as Tally XML", %{conn: conn, statement: statement} do
    conn =
      get(conn, ~p"/banking/#{statement.id}/tally.xml", %{
        "export" => %{
          "bank_ledger_name" => "MY BANK",
          "from" => "2026-06-01",
          "to" => "2026-06-30"
        }
      })

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]
    assert conn.resp_body =~ "<VOUCHERTYPENAME>Receipt</VOUCHERTYPENAME>"
    assert conn.resp_body =~ "<LEDGERNAME>MY BANK</LEDGERNAME>"
    assert conn.resp_body =~ "<LEDGERNAME>Suspense</LEDGERNAME>"
  end

  test "does not expose another firm's statement", %{statement: statement} do
    %{user: outsider} = user_with_org_fixture()
    conn = build_conn() |> log_in_user(outsider) |> get(~p"/banking/#{statement.id}/tally.xml")
    assert response(conn, 404) == "Not found"
  end
end
