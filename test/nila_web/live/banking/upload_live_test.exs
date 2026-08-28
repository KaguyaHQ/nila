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
    refute has_element?(view, "#banking-upload-form label", "Client")
    refute has_element?(view, "#banking-upload-form select[name='statement[client_id]']")
    refute has_element?(view, "#statement_bank_code")

    assert has_element?(
             view,
             "#banking-upload-submit[phx-disable-with='Reading statement…']",
             "Read statement"
           )

    assert has_element?(
             view,
             "#banking-importer",
             "Upload the original bank-generated PDF for Breeze Tech. Nila verifies the balances and prepares the Tally vouchers."
           )

    assert has_element?(
             view,
             "#banking-statement-pdf",
             "Original text PDF · scans are not accepted · up to 20 MB"
           )
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

  test "partial banking validation events do not crash the importer", context do
    {:ok, view, _html} = live(context.conn, ~p"/banking/new")

    upload_html = render_change(view, "validate", %{"_target" => ["statement"]})
    partial_html = render_change(view, "validate", %{})

    assert upload_html =~ "Bring in a bank statement"
    assert partial_html =~ "Bring in a bank statement"
    assert has_element?(view, "#banking-upload-form")
  end

  test "uploads one statement, encrypts its password, and queues extraction", context do
    {:ok, other_client} =
      Clients.create_client(%{org_id: context.org.id, name: "Caltech", type: "company"})

    {:ok, view, _html} = live(context.conn, ~p"/banking")
    upload_pdf(view, "%PDF-1.5 text statement")

    render_submit(view, "submit", %{
      "statement" => %{
        "client_id" => other_client.id,
        "password" => "short-lived"
      }
    })

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

    refute has_element?(view, "#banking-balance-check")
    refute has_element?(view, "#banking-balance-equation")
    refute has_element?(view, "#banking-balance-check-failed")
    refute has_element?(view, "#banking-export-form")
    refute has_element?(view, "#banking-download-tally")
    assert has_element?(view, "#banking-transaction-rows tr", "Test credit")
    assert has_element?(view, "#banking-select-all-transactions:not([checked])")
    refute has_element?(view, "#banking-selection-toolbar")
    refute has_element?(view, "#banking-send-tally")
    assert_push_event(view, "banking-selection", %{ids: []})

    view |> element("#banking-select-all-transactions") |> render_click()

    assert has_element?(view, "#banking-selection[data-phx-component] #banking-selection-toolbar")
    refute has_element?(view, "main #banking-selection-toolbar")
    refute has_element?(view, "#banking-transactions .nila-table-toolbar")
    assert has_element?(view, "#banking-send-tally[form='banking-transaction-form']")
    assert has_element?(view, "#banking-counter-ledger[form='banking-transaction-form']")

    assert has_element?(
             view,
             "#banking-bulk-ledger-trigger[title='Choose ledger']",
             "Choose ledger"
           )

    refute has_element?(view, "#banking-transaction-type")
    assert has_element?(view, "#banking-more-trigger", "More")
    assert has_element?(view, "#banking-more-popover #banking-change-voucher-type")

    assert has_element?(
             view,
             "#banking-more-popover #banking-ignore-selected[form='banking-transaction-form']"
           )

    assert has_element?(view, "#banking-send-tally")
    assert has_element?(view, "#banking-ignore-selected")
    refute has_element?(view, "#banking-restore-selected")
    assert_push_event(view, "banking-selection", %{ids: [selected_id]})
    assert selected_id == transaction.id

    view |> element("#banking-select-transaction-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-select-all-transactions:not([checked])")
    assert_push_event(view, "banking-selection", %{ids: []})
    refute has_element?(view, "#banking-selection-toolbar")

    refute has_element?(
             view,
             "#banking-transaction-rows .nila-bank-cash-amount[data-cash-direction='zero']",
             "₹0.00"
           )

    assert has_element?(
             view,
             "#banking-transaction-rows .nila-bank-cash-amount[data-cash-direction='inflow']",
             "₹25.00"
           )

    assert has_element?(view, "#banking-transactions thead th:nth-child(5)", "Amount")
    assert has_element?(view, "#banking-transactions thead th:nth-child(6)", "Ledger")
  end

  test "balance failures remain visible and block sending", context do
    {:ok, statement} = ready_statement(context)
    [transaction] = statement.bank_transactions

    transaction
    |> Ecto.Changeset.change(balance_paise: transaction.balance_paise + 1)
    |> Repo.update!()

    {:ok, reopened, _html} = live(context.conn, ~p"/banking/#{statement.id}")
    assert has_element?(reopened, "#bank-transaction-#{transaction.id}")
    refute has_element?(reopened, "#banking-balance-check")
    refute has_element?(reopened, "#banking-balance-equation")

    assert has_element?(
             reopened,
             "#banking-balance-check-failed",
             "Balances could not be verified"
           )

    reopened |> element("#banking-select-all-transactions") |> render_click()
    assert has_element?(reopened, "#banking-send-tally[disabled]")

    render_submit(reopened, "bank-transactions", %{
      "transaction_ids" => [to_string(transaction.id)],
      "action" => "send"
    })

    assert has_element?(reopened, "#flash-error", "Balance check failed")
    assert Repo.all(Job) == []
  end

  test "changes voucher type from More without assigning a ledger", context do
    {:ok, statement} = ready_statement(context)
    [transaction] = statement.bank_transactions
    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    view |> element("#banking-select-all-transactions") |> render_click()
    view |> element("#banking-change-voucher-type") |> render_click()
    assert has_element?(view, "#banking-voucher-type-modal", "Counter-ledgers stay unchanged")
    view |> element("#banking-cancel-voucher-type") |> render_click()
    refute has_element?(view, "#banking-voucher-type-modal")
    assert Repo.get!(Transaction, transaction.id).transaction_type == "receipt"

    view |> element("#banking-change-voucher-type") |> render_click()

    view
    |> form("#banking-voucher-type-form", voucher_type: %{voucher_type: "contra"})
    |> render_submit()

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Contra deposit")
    refute has_element?(view, "#banking-voucher-type-modal")
    updated = Repo.get!(Transaction, transaction.id)
    assert updated.transaction_type == "contra_deposit"
    assert updated.counter_ledger_identity == nil
    assert updated.status == "unassigned"

    view |> element("#banking-select-all-transactions") |> render_click()
    view |> element("#banking-change-voucher-type") |> render_click()

    view
    |> form("#banking-voucher-type-form", voucher_type: %{voucher_type: "payment_receipt"})
    |> render_submit()

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Receipt")
    assert Repo.get!(Transaction, transaction.id).transaction_type == "receipt"
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

    assert_push_event(view, "banking-selection", %{ids: [selected_id]})
    assert selected_id == salary.id
    assert has_element?(view, "#banking-selected-transaction-count", "1 selected")

    view
    |> form("#banking-transaction-filters",
      transaction_filters: %{query: "", status: "all", type: "all"}
    )
    |> render_change()

    assert_push_event(view, "banking-selection", %{ids: [^selected_id]})

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

  test "groups attention statuses without allowing uncertain entries to be selected", context do
    {:ok, statement} = ready_statement(context)
    original = hd(statement.bank_transactions)

    rows =
      for {status, ordinal} <-
            Enum.with_index(~w(ready queued posted failed verifying ignored), 2),
          into: %{} do
        transaction =
          Repo.insert!(%Transaction{
            org_id: context.org.id,
            statement_id: statement.id,
            identity: "status-#{status}",
            ordinal: ordinal,
            date: original.date,
            narration: "Status example #{status}",
            withdrawal_paise: 0,
            deposit_paise: 100,
            balance_paise: 2_600,
            transaction_type: "receipt",
            status: status
          })

        {status, transaction}
      end

    {:ok, view, _} = live(context.conn, ~p"/banking/#{statement.id}")
    assert has_element?(view, "#bank-transaction-#{rows["queued"].id}", "Sending")
    refute has_element?(view, "#transaction_filters_status option[value='queued']")
    refute has_element?(view, "#transaction_filters_status option[value='failed']")
    refute has_element?(view, "#transaction_filters_status option[value='verifying']")

    view
    |> form("#banking-transaction-filters", transaction_filters: %{status: "needs_attention"})
    |> render_change()

    assert has_element?(view, "#banking-visible-transaction-count", "2 of 7 transactions shown")
    assert has_element?(view, "#bank-transaction-#{rows["failed"].id}", "Send failed")
    assert has_element?(view, "#bank-transaction-#{rows["verifying"].id}", "Confirmation pending")
    assert has_element?(view, "#banking-select-transaction-#{rows["verifying"].id}[disabled]")
    refute has_element?(view, "#bank-transaction-#{original.id}")

    view |> element("#banking-select-all-transactions") |> render_click()
    assert_push_event(view, "banking-selection", %{ids: [selected_id]})
    assert selected_id == rows["failed"].id

    for {status, label, transaction} <- [
          {"unassigned", "Needs ledger", original},
          {"ready", "Ready to send", rows["ready"]},
          {"posted", "In Tally", rows["posted"]},
          {"ignored", "Ignored", rows["ignored"]}
        ] do
      view
      |> form("#banking-transaction-filters", transaction_filters: %{status: status})
      |> render_change()

      assert has_element?(view, "#banking-visible-transaction-count", "1 of 7 transactions shown")
      assert has_element?(view, "#bank-transaction-#{transaction.id}", label)
      refute has_element?(view, "#bank-transaction-#{rows["failed"].id}")
    end

    view
    |> form("#banking-transaction-filters", transaction_filters: %{status: "all"})
    |> render_change()

    assert has_element?(view, "#banking-visible-transaction-count", "7 transactions")
    assert has_element?(view, "#bank-transaction-#{rows["queued"].id}", "Sending")
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
    refute has_element?(view, "#banking-change-voucher-type")
    refute has_element?(view, "#banking-assign-selected")
    refute has_element?(view, "#banking-ignore-selected")
    refute has_element?(view, "#banking-send-tally")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [transaction_id],
      "counter_ledger_identity" => "",
      "transaction_type" => "",
      "action" => "restore"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Needs ledger")
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
    refute has_element?(view, "#banking-change-voucher-type")
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
    assert has_element?(view, "#banking-statement-page h1", "HDFC Bank · •••• 4587")

    assert has_element?(
             view,
             "#banking-statement-page",
             "Breeze Tech · 01 Jun 2026–02 Jun 2026 · 1 transaction"
           )

    assert has_element?(view, "#banking-tally-company", company.name)
    refute has_element?(view, "#banking-tally-setup-form select[name='tally_setup[company_id]']")
    assert has_element?(view, "#banking-save-tally-destination", "Save")

    view
    |> form("#banking-tally-setup-form",
      tally_setup: %{
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
    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Ready to send")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [Integer.to_string(transaction.id)],
      "counter_ledger_identity" => charges.identity,
      "transaction_type" => "",
      "action" => "map"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Bank Charges")
    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Ready to send")

    render_submit(view, "bank-transactions", %{
      "transaction_ids" => [Integer.to_string(transaction.id)],
      "counter_ledger_identity" => "",
      "transaction_type" => "",
      "action" => "send"
    })

    assert has_element?(view, "#bank-transaction-#{transaction.id}", "Sending")
    assert Repo.one!(Job).source_key == "bank:#{statement.id}:transaction:stub-1"
  end

  test "a configured statement keeps using its saved company after the client default changes",
       context do
    {:ok, statement} = ready_statement(context)
    {:ok, device, _token} = TallyDevices.create_device(context.org, %{name: "Accounts PC"})

    {:ok, [saved_company, new_default]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Dummy Run Company", "tally_guid" => "dummy-run"},
        %{"name" => "Breezetech Manual", "tally_guid" => "breezetech-manual"}
      ])

    saved_bank =
      master(context.org.id, saved_company.id, "dummy-bank", "HDFC Bank - 0443", "Bank Accounts")

    _saved_igst =
      master(context.org.id, saved_company.id, "dummy-igst", "IGST", "Duties & Taxes")

    _new_igst =
      master(context.org.id, new_default.id, "breeze-igst", "Breeze IGST", "Duties & Taxes")

    context.client
    |> Ecto.Changeset.change(active_tally_company_id: saved_company.id)
    |> Repo.update!()

    assert {:ok, _configured} =
             Banking.configure_tally(context.org.id, statement.id, saved_bank.identity)

    context.client
    |> Ecto.Changeset.change(active_tally_company_id: new_default.id)
    |> Repo.update!()

    {:ok, view, _html} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(view, "#banking-tally-company", "Dummy Run Company")
    assert has_element?(view, "#banking-tally-setup-form", "HDFC Bank - 0443")

    transaction = hd(statement.bank_transactions)
    view |> element("#banking-ledger-trigger-#{transaction.id}") |> render_click()

    assert has_element?(view, "#banking-ledger-options", "IGST")
    refute has_element?(view, "#banking-ledger-options", "Breeze IGST")
  end

  test "searches bulk ledgers and assigns only the selected filtered transactions", context do
    {:ok, statement} = ready_statement(context)
    original = hd(statement.bank_transactions)
    {:ok, company} = linked_company(context)
    bank = master(context.org.id, company.id, "hdfc-bank", "HDFC Bank", "Bank Accounts")
    charges = master(context.org.id, company.id, "charges", "Bank Charges", "Indirect Expenses")
    _rent = master(context.org.id, company.id, "rent", "Office Rent", "Indirect Expenses")
    {:ok, _} = Banking.configure_tally(context.org.id, statement.id, bank.identity)

    matching =
      Repo.insert!(%Transaction{
        org_id: context.org.id,
        statement_id: statement.id,
        identity: "second-test-credit",
        ordinal: 2,
        date: original.date,
        narration: "Test credit second",
        withdrawal_paise: 0,
        deposit_paise: 500,
        balance_paise: 3_000,
        transaction_type: "receipt",
        status: "unassigned"
      })

    excluded =
      Repo.insert!(%Transaction{
        org_id: context.org.id,
        statement_id: statement.id,
        identity: "unrelated-payment",
        ordinal: 3,
        date: original.date,
        narration: "Unrelated payment",
        withdrawal_paise: 100,
        deposit_paise: 0,
        balance_paise: 2_900,
        transaction_type: "payment",
        status: "unassigned"
      })

    {:ok, view, _} = live(context.conn, ~p"/banking/#{statement.id}")

    view
    |> form("#banking-transaction-filters", transaction_filters: %{query: "test credit"})
    |> render_change()

    view |> element("#banking-select-all-transactions") |> render_click()
    assert has_element?(view, "#banking-selected-transaction-count", "2 selected")
    assert has_element?(view, "#banking-assign-selected[disabled]")
    view |> element("#banking-bulk-ledger-trigger") |> render_click()
    refute has_element?(view, "#banking-ledger-options", "HDFC Bank")

    view
    |> form("#banking-ledger-filter-form", ledger_filter: %{query: "no such ledger"})
    |> render_change()

    assert has_element?(view, "#banking-ledger-options-empty", "No ledgers match")

    view
    |> form("#banking-ledger-filter-form", ledger_filter: %{query: "CHARGES"})
    |> render_change()

    assert has_element?(view, "#banking-ledger-options", "Bank Charges")
    refute has_element?(view, "#banking-ledger-options", "Office Rent")
    view |> form("#banking-ledger-filter-form") |> render_submit()

    assert has_element?(view, "#banking-bulk-ledger-trigger", "Bank Charges")
    assert has_element?(view, "#banking-counter-ledger[value='charges']")
    assert has_element?(view, "#banking-assign-selected:not([disabled])")
    assert is_nil(Repo.get!(Transaction, original.id).counter_ledger_identity)

    view |> element("#banking-bulk-ledger-trigger") |> render_click()
    assert has_element?(view, "#banking-ledger-options [aria-selected='true']", "Bank Charges")
    view |> element("#banking-ledger-options [phx-value-identity='charges']") |> render_click()

    view
    |> form("#banking-transaction-form", transaction_ids: [original.id, matching.id])
    |> render_submit(%{"action" => "map"})

    for transaction <- [original, matching] do
      assert Repo.get!(Transaction, transaction.id).counter_ledger_identity == charges.identity
      assert has_element?(view, "#bank-transaction-#{transaction.id}", "Bank Charges")
    end

    assert is_nil(Repo.get!(Transaction, excluded.id).counter_ledger_identity)
    refute has_element?(view, "#bank-transaction-#{excluded.id}")
  end

  test "does not open a bulk picker without a destination or an active selection", context do
    {:ok, statement} = ready_statement(context)
    {:ok, view, _} = live(context.conn, ~p"/banking/#{statement.id}")
    view |> element("#banking-select-all-transactions") |> render_click()
    assert has_element?(view, "#banking-bulk-ledger-trigger[disabled]")
    render_click(view, "open-bulk-ledger-picker")
    refute has_element?(view, "#banking-ledger-options [data-selectable-option]")
  end

  test "the single amount column preserves reversal signs and cash direction", context do
    {:ok, statement} = ready_statement(context)
    original = hd(statement.bank_transactions)

    original =
      original
      |> Ecto.Changeset.change(
        withdrawal_paise: -100,
        deposit_paise: 0,
        transaction_type: "payment"
      )
      |> Repo.update!()

    {:ok, view, _} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(
             view,
             "#bank-transaction-#{original.id} [data-cash-direction='inflow']",
             "-1.00"
           )

    original
    |> Ecto.Changeset.change(
      withdrawal_paise: 0,
      deposit_paise: -200,
      transaction_type: "receipt"
    )
    |> Repo.update!()

    {:ok, view, _} = live(context.conn, ~p"/banking/#{statement.id}")

    assert has_element?(
             view,
             "#bank-transaction-#{original.id} [data-cash-direction='outflow']",
             "-2.00"
           )
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

    {:ok, company}
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
