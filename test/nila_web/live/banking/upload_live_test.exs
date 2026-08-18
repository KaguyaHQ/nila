defmodule NilaWeb.Banking.UploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Clients
  alias Nila.Storage

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})
    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "offers the bank-generated PDF workflow from the Banking rail entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/banking")

    assert has_element?(view, "#banking-upload-page")
    assert has_element?(view, "a[aria-current='page']", "Banking")
    assert has_element?(view, "#banking-upload-form")
    assert has_element?(view, "#banking-statement-pdf input[type=file][accept='.pdf']")
    assert has_element?(view, "#statement_password[type=password]")
    assert render(view) =~ "Kotak Mahindra Bank / 811"
    assert render(view) =~ "without OCR"
  end

  test "uploads one statement, encrypts its password, and queues extraction", context do
    {:ok, view, _html} = live(context.conn, ~p"/banking")
    upload_pdf(view, "%PDF-1.5 text statement")

    view
    |> form("#banking-upload-form",
      statement: %{
        client_id: context.client.id,
        bank_code: "kotak",
        bank_ledger_name: "MY KOTAK",
        password: "short-lived"
      }
    )
    |> render_submit()

    assert [statement] = Nila.Repo.all(Nila.Banking.Statement)
    assert_redirect(view, ~p"/banking/#{statement.id}")
    assert statement.org_id == context.org.id
    assert statement.client_id == context.client.id
    assert statement.bank_code == "kotak"
    assert statement.bank_ledger_name == "MY KOTAK"
    assert statement.source_credentials == %{"password" => "short-lived"}
    assert_enqueued(worker: StatementWorker, args: %{statement_id: statement.id})
  end

  test "shows the extracted table and Tally controls", context do
    {:ok, statement} = ready_statement(context)
    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(view, "#banking-statement-summary", "Opening balance")
    assert has_element?(view, "#banking-export-form")
    assert has_element?(view, "#banking-download-tally", "Download Tally XML")
    assert has_element?(view, "#banking-transaction-rows tr", "Test credit")

    assert has_element?(
             view,
             "#banking-transaction-rows .nila-bank-cash-amount[data-cash-direction='zero']",
             "₹0.00"
           )

    assert has_element?(
             view,
             "#banking-transaction-rows .nila-bank-cash-amount[data-cash-direction='inflow']",
             "₹25.00"
           )

    assert render(view) =~ "1 transactions · balances reconcile"
  end

  defp upload_pdf(view, content) do
    upload =
      file_input(view, "#banking-upload-form", :statement, [
        %{name: "statement.pdf", content: content, type: "application/pdf"}
      ])

    render_upload(upload, "statement.pdf", 0)
    ref = hd(upload.entries)["ref"]
    key = :sys.get_state(view.pid).socket.assigns.entry_keys |> Map.fetch!(ref)
    {:ok, _stored} = Storage.put(key, content, content_type: "application/pdf")
    assert render_upload(upload, "statement.pdf", 100) =~ "statement.pdf"
  end

  defp ready_statement(context) do
    {:ok, statement} =
      Banking.record_statement(
        %{
          org_id: context.org.id,
          client_id: context.client.id,
          brought_in_by_id: context.user.id
        },
        %{
          bank_code: "hdfc",
          bank_name: "HDFC Bank",
          bank_ledger_name: "HDFC Bank",
          source_key: "orgs/#{context.org.id}/bank-statements/ready/original.pdf",
          original_filename: "statement.pdf"
        }
      )

    {:ok, _stored} = Storage.put(statement.source_key, "%PDF", content_type: "application/pdf")
    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})
    Banking.get_statement(context.org.id, statement.id)
  end
end
