defmodule NilaWeb.Banking.UploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Banking
  alias Nila.Banking.StatementWorker
  alias Nila.Banking.Transaction
  alias Nila.Clients
  alias Nila.Repo
  alias Nila.Storage
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyJobs.Job

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})
    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "offers the bank-generated PDF workflow from the Banking rail entry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/banking")

    assert has_element?(view, "#banking-page")
    assert has_element?(view, "a[aria-current='page']", "Banking")
    assert has_element?(view, "#banking-importer[data-importer]")
    assert has_element?(view, "#banking-upload-form-card")
    assert has_element?(view, "#banking-upload-form")
    assert has_element?(view, "#banking-statement-pdf input[type=file][accept='.pdf']")
    assert has_element?(view, "label[for='statement_password']", "PDF password (optional)")
    assert has_element?(view, "#statement_password[type=password]")
    refute has_element?(view, "#statement_bank_code")

    assert has_element?(
             view,
             "#banking-upload-submit[phx-disable-with='Reading statement…']",
             "Read statement"
           )

    assert render(view) =~ "without OCR"
  end

  test "banking becomes a statement workspace after the first import", context do
    {:ok, statement} = ready_statement(context)
    {:ok, view, _html} = live(context.conn, ~p"/banking")

    assert has_element?(view, "#banking-page", "Bank statements")
    assert has_element?(view, "#banking-bring-statement[href='/banking/new']")
    refute has_element?(view, "#banking-importer")
    refute has_element?(view, "#banking-upload-form")

    assert has_element?(view, "#banking-statements", "Statements")
    assert has_element?(view, "#banking-statements-table", "statement.pdf")
    assert has_element?(view, "#banking-statements-table", "Breeze Tech")
    assert has_element?(view, "#banking-statements-table", "HDFC Bank")
    assert has_element?(view, "#banking-statements-table", "1 transaction")
    assert has_element?(view, "#banking-statements-table", "1 needs review")

    assert has_element?(
             view,
             "#banking-statement-#{statement.id} a[href='/banking/#{statement.id}']"
           )
  end

  test "bring in statement opens the temporary importer", context do
    {:ok, _statement} = ready_statement(context)
    {:ok, view, _html} = live(context.conn, ~p"/banking/new")

    assert has_element?(view, "#banking-importer[data-importer]")
    assert has_element?(view, "#banking-page", "Bring in a bank statement")
    assert has_element?(view, "#banking-page a[href='/banking']", "Banking")
    refute has_element?(view, "#banking-statements")
  end

  test "uploads one statement, encrypts its password, and queues extraction", context do
    {:ok, view, _html} = live(context.conn, ~p"/banking")
    upload_pdf(view, "%PDF-1.5 text statement")

    view
    |> form("#banking-upload-form",
      statement: %{
        client_id: context.client.id,
        password: "short-lived"
      }
    )
    |> render_submit()

    assert [statement] = Nila.Repo.all(Nila.Banking.Statement)
    assert_redirect(view, ~p"/banking/#{statement.id}")
    assert statement.org_id == context.org.id
    assert statement.client_id == context.client.id
    assert statement.bank_code == nil
    assert statement.bank_ledger_name == nil
    assert statement.source_credentials == %{"password" => "short-lived"}
    assert_enqueued(worker: StatementWorker, args: %{statement_id: statement.id})
  end

  test "shows the extracted table and Tally controls", context do
    {:ok, statement} = ready_statement(context)
    transaction = hd(statement.bank_transactions)
    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(view, "#banking-statement-summary", "Opening balance")
    refute has_element?(view, "#banking-export-form")
    refute has_element?(view, "#banking-download-tally")
    assert has_element?(view, "#banking-transaction-rows tr", "Test credit")
    assert has_element?(view, "#banking-select-all-transactions:not([checked])")
    refute has_element?(view, "#banking-selection-toolbar")
    refute has_element?(view, "#banking-send-tally")

    view |> element("#banking-select-all-transactions") |> render_click()

    assert has_element?(view, "#banking-select-all-transactions[checked]")
    assert has_element?(view, "#banking-selection-toolbar")
    assert has_element?(view, "#banking-send-tally")
    assert has_element?(view, "#banking-ignore-selected")
    refute has_element?(view, "#banking-restore-selected")
    assert has_element?(view, "#banking-select-transaction-#{transaction.id}[checked]")

    view |> element("#banking-select-transaction-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-select-all-transactions:not([checked])")
    refute has_element?(view, "#banking-select-transaction-#{transaction.id}[checked]")
    refute has_element?(view, "#banking-selection-toolbar")

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
  end

  test "filters transactions and selects only the filtered rows", context do
    {:ok, statement} = ready_statement(context)
    original = hd(statement.bank_transactions)
    assert original.status == "unassigned"

    salary =
      Repo.insert!(%Transaction{
        org_id: context.org.id,
        statement_id: statement.id,
        identity: "salary-payment",
        ordinal: 2,
        date: ~D[2024-09-04],
        narration: "NEFT DR SALARY PRASHANT THAPA",
        reference: "SALARY-REF-2",
        withdrawal_paise: 7_000_000,
        deposit_paise: 0,
        balance_paise: 35_958_800,
        transaction_type: "payment",
        counter_ledger_identity: "salary-payable",
        counter_ledger_name: "Salary Payable",
        status: "ready"
      })

    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(view, "#banking-visible-transaction-count", "2 transactions")
    refute has_element?(view, "#banking-selected-transaction-count")

    view
    |> form("#banking-transaction-filters",
      transaction_filters: %{query: "salary-ref", status: "all", type: "all"}
    )
    |> render_change()

    assert has_element?(view, "#banking-visible-transaction-count", "1 of 2 transactions shown")
    assert has_element?(view, "#bank-transaction-#{salary.id}")
    refute has_element?(view, "#bank-transaction-#{original.id}")

    view |> element("#banking-select-all-transactions") |> render_click()

    assert has_element?(view, "#banking-select-transaction-#{salary.id}[checked]")
    assert has_element?(view, "#banking-selected-transaction-count", "1 selected")

    view
    |> form("#banking-transaction-filters",
      transaction_filters: %{query: "", status: "all", type: "all"}
    )
    |> render_change()

    assert has_element?(view, "#banking-select-transaction-#{salary.id}[checked]")
    assert has_element?(view, "#banking-select-all-transactions[data-indeterminate='true']")

    view
    |> form("#banking-transaction-filters",
      transaction_filters: %{query: "", status: "unassigned", type: "all"}
    )
    |> render_change()

    assert has_element?(view, "#bank-transaction-#{original.id}")
    refute has_element?(view, "#bank-transaction-#{salary.id}")
    refute has_element?(view, "#banking-selected-transaction-count")

    view
    |> form("#banking-transaction-filters",
      transaction_filters: %{query: "", status: "all", type: "payment"}
    )
    |> render_change()

    assert has_element?(view, "#bank-transaction-#{salary.id}")
    refute has_element?(view, "#bank-transaction-#{original.id}")
  end

  test "shows only actions relevant to the selected transaction status", context do
    {:ok, statement} = ready_statement(context)
    transaction = hd(statement.bank_transactions)
    transaction_id = Integer.to_string(transaction.id)
    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    view |> element("#banking-select-transaction-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-assign-selected")
    assert has_element?(view, "#banking-ignore-selected")
    assert has_element?(view, "#banking-send-tally")
    refute has_element?(view, "#banking-restore-selected")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [transaction_id],
      "counter_ledger_identity" => "",
      "transaction_type" => "",
      "action" => "ignore"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Ignored")
    refute has_element?(view, "#banking-selection-toolbar")

    view |> element("#banking-select-transaction-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-restore-selected")
    refute has_element?(view, "#banking-assign-selected")
    refute has_element?(view, "#banking-ignore-selected")
    refute has_element?(view, "#banking-send-tally")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [transaction_id],
      "counter_ledger_identity" => "",
      "transaction_type" => "",
      "action" => "restore"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Unassigned")
  end

  test "keeps assignment and sending out of mixed-status selections", context do
    {:ok, statement} = ready_statement(context)
    ignored = hd(statement.bank_transactions)
    {:ok, [_ignored]} = Banking.set_ignored(context.org.id, statement.id, [ignored.id], true)

    active =
      Repo.insert!(%Transaction{
        org_id: context.org.id,
        statement_id: statement.id,
        identity: "mixed-selection-active",
        ordinal: 2,
        date: ~D[2024-09-04],
        narration: "Active transaction",
        withdrawal_paise: 100,
        deposit_paise: 0,
        balance_paise: 2_400,
        transaction_type: "payment",
        status: "unassigned"
      })

    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    view |> element("#banking-select-transaction-#{ignored.id}") |> render_click()
    view |> element("#banking-select-transaction-#{active.id}") |> render_click()

    assert has_element?(view, "#banking-selection-toolbar", "Mixed statuses")
    assert has_element?(view, "#banking-ignore-selected", "Ignore active")
    assert has_element?(view, "#banking-restore-selected", "Restore ignored")
    refute has_element?(view, "#banking-assign-selected")
    refute has_element?(view, "#banking-send-tally")
  end

  test "configures synced ledgers, maps a row, and sends it through the connector", context do
    {:ok, statement} = ready_statement(context)
    {:ok, company} = linked_company(context)
    bank = master(context.org.id, company.id, "hdfc-bank", "HDFC Bank", "Bank Accounts")

    charges =
      master(context.org.id, company.id, "bank-charges", "Bank Charges", "Indirect Expenses")

    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")
    assert has_element?(view, "#banking-transactions > #banking-tally-setup")
    refute has_element?(view, "#banking-tally-setup.nila-card")

    view
    |> form("#banking-tally-setup-form",
      tally_setup: %{
        company_id: Integer.to_string(company.id),
        bank_ledger_identity: bank.identity
      }
    )
    |> render_submit()

    transaction = hd(Banking.list_transactions(context.org.id, statement.id))

    view |> element("#banking-ledger-trigger-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-ledger-picker[popover='auto']")
    assert has_element?(view, "#banking-ledger-filter-form")
    refute has_element?(view, "#banking-ledger-options", "HDFC Bank")

    view
    |> form("#banking-ledger-filter-form", ledger_filter: %{query: "charges"})
    |> render_change()

    assert has_element?(view, "#banking-ledger-options", "Bank Charges")

    view
    |> element("#banking-ledger-options [phx-value-identity='bank-charges']")
    |> render_click()

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Bank Charges")
    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Ready")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [Integer.to_string(transaction.id)],
      "counter_ledger_identity" => charges.identity,
      "transaction_type" => "",
      "action" => "map"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Bank Charges")
    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Ready")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [Integer.to_string(transaction.id)],
      "counter_ledger_identity" => "",
      "transaction_type" => "",
      "action" => "send"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Queued")
    assert Repo.one!(Job).source_key == "bank:#{statement.id}:transaction:stub-1"
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
          source_key: "orgs/#{context.org.id}/bank-statements/ready/original.pdf",
          original_filename: "statement.pdf"
        }
      )

    {:ok, _stored} = Storage.put(statement.source_key, "%PDF", content_type: "application/pdf")
    assert :ok = perform_job(StatementWorker, %{statement_id: statement.id})
    Banking.get_statement(context.org.id, statement.id)
  end

  defp linked_company(context) do
    {:ok, device, _token} = TallyDevices.create_device(context.org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => context.client.name, "tally_guid" => "company-breeze"}
      ])

    context.client
    |> Ecto.Changeset.change(active_tally_company_id: company.id)
    |> Repo.update!()

    {:ok, Repo.preload(company, :device)}
  end

  defp master(org_id, company_id, identity, name, parent) do
    %SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "ledger",
      identity: identity,
      name: name,
      data: %{"parent" => parent}
    }
    |> Repo.insert!()
  end
end
