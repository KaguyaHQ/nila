defmodule NilaWeb.Gst.SalesBillsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.{Gstr1, InvoiceRemoval, TallyPacket}
  alias Nila.Storage
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyJobs
  alias Nila.TallyMappings
  alias NilaWeb.Presence

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "29",
          "invoice_number" => "INV-001",
          "invoice_date" => "15.07.2026",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{"name" => "Customer & Co", "gstin" => "29AAVCS8021P1ZB"},
          "line_items" => [
            %{
              "description" => "Technical support services",
              "hsn_sac" => "998719",
              "taxable_value" => 1_000,
              "igst_rate" => 18,
              "igst_amount" => 180
            }
          ]
        }
      })

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2026-07",
          kind: "sales",
          status: "extracted",
          invoices: [invoice],
          meta: %{"sales_batch" => true, "original_name" => "sales.pdf"}
        }
      )

    invoice = Map.put(invoice, "image", "d#{dump.id}_page_01.png")
    dump = dump |> Ecto.Changeset.change(invoices: [invoice]) |> Nila.Repo.update!()

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Office PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{
          "name" => "Breeze Tech",
          "tally_guid" => "breeze-guid",
          "gstin" => client.gstin
        }
      ])

    {:ok, _presence_ref} =
      Presence.track(
        self(),
        "tally_devices:#{org.id}",
        Integer.to_string(device.id),
        %{device_id: device.id, name: device.name}
      )

    sync_demo_masters(org.id, company.id)

    %{
      conn: log_in_user(conn, user),
      org: org,
      client: client,
      dump: dump,
      device: device,
      company: company
    }
  end

  test "serves workbench evidence from its dump without requiring a filing month", %{
    conn: conn,
    client: client,
    dump: dump,
    org: org
  } do
    basename = "d#{dump.id}_page_01.png"
    key = SalesMonths.evidence_key(org.id, client.id, dump.period, basename)
    {:ok, _stored} = Storage.put(key, "sales-evidence")

    conn =
      get(conn, ~p"/sales-bills/#{client.id}/dumps/#{dump.id}/evidence/#{basename}")

    assert response(conn, 200) == "sales-evidence"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "sales workbench evidence is dump- and tenant-scoped", %{
    client: client,
    dump: dump
  } do
    %{user: other_user} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)
    basename = "d#{dump.id}_page_01.png"

    conn =
      get(conn, ~p"/sales-bills/#{client.id}/dumps/#{dump.id}/evidence/#{basename}")

    assert response(conn, 404)
  end

  test "sends the prepared vouchers to the open Tally company", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device
  } do
    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    assert has_element?(view, "#sales-bills-send-to-tally", "Send to Tally")
    refute has_element?(view, "#sales-bills-download")
    refute has_element?(view, "#sales-bills-remainder")
    assert has_element?(view, "#sales-bills-voucher-table a[href$='?item=INV-001']")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Ready")

    view
    |> element("#sales-bills-send-to-tally")
    |> render_click()

    assert has_element?(view, "#sales-bills-sending-to-tally", "Sending to Tally")
    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert job.payload["company"] == "Breeze Tech"
    assert job.payload["invoice_number"] == "INV-001"
    assert job.payload["xml"] =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"

    assert {:ok, _job} =
             TallyJobs.complete(device.id, job.id, "succeeded", %{"created" => 1})

    assert render(view) =~ "Added to Tally"
    assert has_element?(view, "#sales-bills-added-to-tally")
  end

  test "ignores other open companies and sends only to the client's destination", %{
    conn: conn,
    org: org,
    client: client,
    dump: dump,
    device: device
  } do
    {:ok, second_device, _token} = TallyDevices.create_device(org, %{name: "Second PC"})

    {:ok, [second_company]} =
      TallyDevices.report_companies(second_device, [
        %{
          "name" => "Dummy Run Company",
          "tally_guid" => "dummy-guid",
          "gstin" => client.gstin
        }
      ])

    {:ok, _presence_ref} =
      Presence.track(
        self(),
        "tally_devices:#{org.id}",
        Integer.to_string(second_device.id),
        %{device_id: second_device.id, name: second_device.name}
      )

    sync_demo_masters(org.id, second_company.id)
    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    refute has_element?(view, "#sales-bills-tally-company-form")
    assert has_element?(view, "#sales-bills-tally-destination", "Tally · Breeze Tech")

    refute Enum.any?(
             TallyDevices.list_linked_companies(org.id),
             &(&1.id == second_company.id)
           )

    view |> element("#sales-bills-send-to-tally") |> render_click()

    assert [%{device_id: device_id, payload: payload}] = Nila.Repo.all(Nila.TallyJobs.Job)
    assert device_id == device.id
    assert payload["company"] == "Breeze Tech"
  end

  test "keeps cached Tally mappings available while the connector is offline", %{
    conn: conn,
    org: org,
    client: client,
    dump: dump,
    device: device
  } do
    :ok =
      Presence.untrack(
        self(),
        "tally_devices:#{org.id}",
        Integer.to_string(device.id)
      )

    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001")

    assert has_element?(view, "#sales-bills-send-to-tally[disabled]")
    refute has_element?(view, "#sales-bills-download")
    assert has_element?(view, "#sales-bill-tally-offline", "Nila Connector is offline")
    assert has_element?(view, "#sales-bill-tally-posting-form")
    refute has_element?(view, "#tally_posting_party_ledger_identity[disabled]")
    refute has_element?(view, "#tally-posting-line-sales-ledger-0[disabled]")

    render_submit(view, "save-tally-posting", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "sales_ledger_identity" => "name:sales",
        "igst_ledger_identity" => "name:output igst",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "invoice" => %{}
      }
    })

    assert_patch(view, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    {:ok, _presence_ref} =
      Presence.track(
        self(),
        "tally_devices:#{org.id}",
        Integer.to_string(device.id),
        %{device_id: device.id, name: device.name}
      )

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#sales-bills-send-to-tally[disabled]")
  end

  test "shows invoice facts but disables Tally mappings before the first master sync", %{
    conn: conn,
    org: org,
    client: client,
    dump: dump,
    company: company
  } do
    Nila.Repo.delete_all(
      from master in SyncedMaster,
        where: master.org_id == ^org.id and master.company_id == ^company.id
    )

    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001")

    assert has_element?(view, "#sales-bill-tally-posting-form")
    assert has_element?(view, "#sales-bill-invoice-identity", "INV-001")

    assert has_element?(
             view,
             "#sales-bill-tally-masters-unavailable",
             "Tally masters need syncing"
           )

    assert has_element?(view, "#tally_posting_party_ledger_identity[disabled]")
    assert has_element?(view, "#tally-posting-line-sales-ledger-0[disabled]")
    assert has_element?(view, "#tally_posting_igst_ledger_identity[disabled]")
    assert has_element?(view, "#sales-bill-posting-awaiting-masters")
    refute has_element?(view, "#sales-bill-save-tally-posting")

    view |> element("#sales-bill-edit-invoice-facts") |> render_click()

    render_submit(view, "save-invoice-facts", %{
      "invoice_facts" => %{
        "invoice_number" => "INV-001",
        "invoice_date" => "2026-07-15",
        "buyer_name" => "Corrected Customer",
        "buyer_gstin" => "29AAVCS8021P1ZB",
        "place_of_supply" => "29"
      }
    })

    assert has_element?(view, "#sales-bill-buyer-identity", "Corrected Customer")
  end

  test "keeps the proposed voucher visible before a Tally company is selected", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    Nila.Repo.get!(Nila.Clients.Client, client.id)
    |> Ecto.Changeset.change(active_tally_company_id: nil)
    |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001")

    assert has_element?(view, "#sales-bill-tally-posting-form")
    assert has_element?(view, "#sales-bill-invoice-identity", "INV-001")

    assert has_element?(
             view,
             "#sales-bill-tally-company-unavailable",
             "No Tally company selected"
           )

    assert has_element?(view, "#tally_posting_party_ledger_identity[disabled]")
    assert has_element?(view, "#sales-bills-download")
  end

  test "confirms once and sends ready plus warned invoices while skipping blocked invoices", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices

    warned =
      invoice
      |> Map.put("id", "source-warning")
      |> Map.put("invoice_number", "INV-WARNING")
      |> Map.put("printed_total_taxable", 900)

    blocked =
      invoice
      |> Map.put("id", "source-blocked")
      |> Map.put("invoice_number", "INV-BLOCKED")
      |> Map.put("supply_type", "export")
      |> Map.put("document", %{"export" => true})

    dump =
      dump
      |> Ecto.Changeset.change(invoices: [invoice, warned, blocked])
      |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    assert has_element?(view, "#sales-bill-delivery-INV-001", "Ready")
    assert has_element?(view, "#sales-bill-delivery-source-warning", "Needs review")
    assert has_element?(view, "#sales-bill-delivery-source-blocked", "Cannot send")

    view |> element("#sales-bills-send-to-tally") |> render_click()

    assert has_element?(
             view,
             "#sales-bills-tally-warning-dialog",
             "1 invoice still needs review"
           )

    assert has_element?(view, "#sales-bills-tally-warning-dialog", "INV-WARNING")
    assert has_element?(view, "#sales-bills-tally-warning-cancel", "Cancel")
    assert has_element?(view, "#sales-bills-tally-warning-confirm", "Send 2 anyway")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0

    view |> element("#sales-bills-tally-warning-confirm") |> render_click()

    jobs = Nila.Repo.all(Nila.TallyJobs.Job)

    assert jobs |> Enum.map(& &1.payload["invoice_number"]) |> Enum.sort() == [
             "INV-001",
             "INV-WARNING"
           ]
  end

  test "closes invoice review with Escape", %{conn: conn, client: client, dump: dump} do
    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001")

    assert has_element?(
             view,
             "#sales-bill-posting-review-focus-wrap[phx-window-keydown='close-posting-review'][phx-key='escape']"
           )
  end

  test "shows an unexportable invoice as review work and makes it ready after correction", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices

    dump =
      dump
      |> Ecto.Changeset.change(invoices: [Map.put(invoice, "place_of_supply", "Chennai")])
      |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#sales-bills-result", "No sales vouchers ready")
    assert has_element?(view, "#sales-bills-voucher-table", "INV-001")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Cannot send")

    assert has_element?(
             view,
             "#sales-bills-needs-review",
             "Tally export and place of supply need review."
           )

    view |> element("#sales-bill-review-INV-001") |> render_click()

    assert_patch(view, path <> "?item=INV-001")
    assert has_element?(view, "#sales-bill-posting-review")
    assert has_element?(view, "#sales-bill-review-issues", "Chennai")

    render_submit(view, "save-tally-posting", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "sales_ledger_identity" => "name:sales",
        "igst_ledger_identity" => "name:output igst",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "invoice" => %{"place_of_supply" => "29"}
      }
    })

    assert_patch(view, path)
    refute has_element?(view, "#sales-bills-needs-review")
    assert has_element?(view, "#sales-bills-voucher-table", "INV-001")
  end

  test "summarizes arithmetic failures instead of dumping validator calculations", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices
    [line] = invoice["line_items"]

    line =
      Map.merge(line, %{
        "hsn_sac" => nil,
        "taxable_value" => 6_388_200.0,
        "printed_line_amount" => 6_388_200.0,
        "igst_amount" => 1_152.9
      })

    invoice =
      Map.merge(invoice, %{
        "line_items" => [line],
        "printed_total_taxable" => 1_000.0,
        "printed_total_tax" => 180.0,
        "printed_grand_total" => 1_180.0
      })

    dump = dump |> Ecto.Changeset.change(invoices: [invoice]) |> Nila.Repo.update!()
    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(
             view,
             "#sales-bill-review-INV-001",
             "Invoice totals, tax calculations, and HSN/SAC need review."
           )

    refute has_element?(view, "#sales-bills-needs-review", "does not match")

    view |> element("#sales-bill-review-INV-001") |> render_click()

    assert has_element?(
             view,
             "#sales-bill-review-issues",
             "Printed taxable is ₹1,000.00; extracted lines total ₹63,88,200.00."
           )

    assert has_element?(
             view,
             "#sales-bill-review-issues",
             "Printed tax is ₹180.00; extracted lines total ₹1,152.90."
           )

    assert has_element?(view, "#sales-bill-review-issues", "1 line needs review.")
    assert has_element?(view, "#sales-bill-review-issues", "HSN/SAC is missing on 1 line.")
    assert has_element?(view, "#sales-bill-ledger-allocations .nila-callout[data-kind='warning']")

    assert has_element?(
             view,
             "#sales-bill-line-summary-0",
             "HSN/SAC is missing on 1 line."
           )

    refute has_element?(view, "#sales-bill-review-issues", "does not match")
  end

  test "names missing HSN/SAC in the review queue", %{conn: conn, client: client, dump: dump} do
    [invoice] = dump.invoices
    invoice = put_in(invoice, ["line_items", Access.at(0), "hsn_sac"], nil)
    dump = dump |> Ecto.Changeset.change(invoices: [invoice]) |> Nila.Repo.update!()

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{TallyPacket.ref([dump])}")

    assert has_element?(
             view,
             "#sales-bill-review-INV-001",
             "HSN/SAC is missing on 1 line."
           )

    refute has_element?(view, "#sales-bills-needs-review", "could not prepare")
  end

  test "presents a tax-head conflict as tax treatment, not an amount mismatch", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices
    [line] = invoice["line_items"]

    line =
      line
      |> Map.drop(~w(igst_rate igst_amount))
      |> Map.merge(%{
        "cgst_rate" => 9,
        "cgst_amount" => 90,
        "sgst_rate" => 9,
        "sgst_amount" => 90
      })

    invoice = invoice |> Map.put("place_of_supply", "36") |> Map.put("line_items", [line])
    dump = dump |> Ecto.Changeset.change(invoices: [invoice]) |> Nila.Repo.update!()
    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    assert has_element?(
             view,
             "#sales-bill-review-INV-001",
             "Tax treatment doesn’t match the place of supply."
           )

    refute has_element?(view, "#sales-bills-needs-review", "Line amounts")

    view |> element("#sales-bill-review-INV-001") |> render_click()

    assert has_element?(
             view,
             "#sales-bill-review-issues",
             "Seller state is Tamil Nadu and place of supply is Telangana, but the invoice uses CGST/SGST."
           )

    assert has_element?(
             view,
             "#sales-bill-invoice-facts .nila-callout[data-kind='warning']",
             "Tax treatment doesn’t match the place of supply."
           )

    assert has_element?(view, "#sales-bill-place-of-supply", "Telangana")
    refute has_element?(view, "#tally-posting-place-of-supply")

    view |> element("#sales-bill-fix-place-of-supply-0") |> render_click()

    assert has_element?(view, "#sales-bill-invoice-facts-sheet[data-variant='sheet']")
    assert has_element?(view, "#invoice_facts_place_of_supply[autofocus]")

    refute has_element?(view, "#sales-bill-review-issues", "Nila read")
  end

  test "excludes and restores an unsent invoice without touching its source", %{
    conn: conn,
    client: client,
    dump: dump,
    org: org
  } do
    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#sales-bill-actions-INV-001-trigger[aria-label]")

    view |> element("#sales-bill-remove-INV-001") |> render_click()

    assert has_element?(view, "#sales-bill-remove-dialog", "Leave invoice out?")

    assert has_element?(
             view,
             "#sales-bill-remove-dialog",
             "It won’t be sent to Tally. You can include it again before sending."
           )

    view |> element("#sales-bill-remove-cancel") |> render_click()
    refute has_element?(view, "#sales-bill-remove-dialog")

    view |> element("#sales-bill-remove-INV-001") |> render_click()
    view |> element("#sales-bill-remove-confirm") |> render_click()

    assert has_element?(view, "#sales-bills-result", "No sales vouchers ready")
    assert has_element?(view, "#sales-bills-voucher-table", "INV-001")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Not included")
    assert has_element?(view, "#sales-bill-restore-INV-001", "Include")
    refute has_element?(view, "#sales-bill-remove-dialog")

    removal = Nila.Repo.one!(InvoiceRemoval)
    assert removal.org_id == org.id
    assert removal.client_id == client.id
    assert removal.batch_ref == batch_ref
    assert removal.source_id == "INV-001"
    assert removal.removed_at

    assert [source_invoice] = Nila.Repo.reload!(dump).invoices
    assert source_invoice["invoice_number"] == "INV-001"
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0

    {:ok, reopened, _html} = live(conn, path)
    assert has_element?(reopened, "#sales-bills-result", "No sales vouchers ready")
    assert has_element?(reopened, "#sales-bill-delivery-INV-001", "Not included")

    reopened |> element("#sales-bill-restore-INV-001") |> render_click()

    assert has_element?(reopened, "#sales-bill-delivery-INV-001", "Ready")
    refute has_element?(reopened, "#sales-bill-restore-INV-001")
    assert Nila.Repo.aggregate(InvoiceRemoval, :count) == 0
  end

  test "locks invoice editing and removal after the batch is queued", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    view |> element("#sales-bills-send-to-tally") |> render_click()

    refute has_element?(view, "#sales-bill-actions-INV-001-trigger")

    {:ok, view, _html} =
      view
      |> element("#sales-bills-voucher-table a[href$='?item=INV-001']")
      |> render_click()
      |> follow_redirect(conn)

    assert has_element?(view, "#sales-bill-edit-line-0[disabled]")
    assert has_element?(view, "#sales-bill-save-tally-posting[disabled]")
  end

  test "uses the confirmed party and company posting ledgers when sending", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device,
    company: company
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {identity, name, parent} <- [
          {"ledger:customer-ap", "Customer & Co - AP", "Sundry Debtors"},
          {"ledger:material-sales", "Material Sales", "Sales Accounts"},
          {"ledger:output-igst", "IGST Output @ 18%", "Duties & Taxes"}
        ] do
      Nila.Repo.insert!(%SyncedMaster{
        org_id: company.org_id,
        company_id: company.id,
        kind: "ledger",
        identity: identity,
        name: name,
        data: %{"parent" => parent},
        inserted_at: now,
        updated_at: now
      })
    end

    [invoice] = dump.invoices

    assert {:ok, _mapping} =
             TallyMappings.save_confirmed_party_choice(
               company.org_id,
               company.id,
               %{
                 gstin: invoice["buyer_gstin"],
                 name: invoice["buyer_name"],
                 source_key: invoice["id"]
               },
               "ledger:customer-ap"
             )

    assert {:ok, _profile} =
             TallyMappings.save_posting_profile(company.org_id, company.id, %{
               sales_ledger_identity: "ledger:material-sales",
               igst_ledger_identity: "ledger:output-igst"
             })

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")
    view |> element("#sales-bills-send-to-tally") |> render_click()

    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert job.payload["xml"] =~ "<PARTYLEDGERNAME>Customer &amp; Co - AP</PARTYLEDGERNAME>"
    assert job.payload["xml"] =~ "<LEDGERNAME>Material Sales</LEDGERNAME>"
    assert job.payload["xml"] =~ "<LEDGERNAME>IGST Output @ 18%</LEDGERNAME>"
    refute job.payload["xml"] =~ "<LEDGERNAME>Output IGST</LEDGERNAME>"
  end

  test "blocks sales vouchers when Tally controls the voucher number", %{
    conn: conn,
    client: client,
    dump: dump,
    company: company
  } do
    Nila.Repo.get_by!(SyncedMaster, company_id: company.id, kind: "voucher_type", name: "Sales")
    |> Ecto.Changeset.change(data: %{"numbering_method" => "Default"})
    |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    view
    |> element("#sales-bills-send-to-tally")
    |> render_click()

    assert has_element?(
             view,
             "#sales-bills-send-error",
             "Sales voucher numbering in Tally must be Manual or Automatic (Manual Override)"
           )

    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0
  end

  test "holds a voucher whose referenced Tally ledger is missing", %{
    conn: conn,
    client: client,
    dump: dump,
    company: company
  } do
    Nila.Repo.get_by!(SyncedMaster,
      company_id: company.id,
      kind: "ledger",
      name: "Output IGST"
    )
    |> Nila.Repo.delete!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    view
    |> element("#sales-bills-send-to-tally")
    |> render_click()

    assert has_element?(view, "#sales-bills-send-error", "Held back 1 voucher (INV-001)")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Needs review")
    assert render(view) =~ "Output IGST"
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0
  end

  test "blocks sending when a registered party cannot be resolved to an existing ledger", %{
    conn: conn,
    client: client,
    dump: dump,
    company: company
  } do
    Nila.Repo.get_by!(SyncedMaster,
      company_id: company.id,
      kind: "ledger",
      name: "Customer & Co"
    )
    |> Nila.Repo.delete!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")
    view |> element("#sales-bills-send-to-tally") |> render_click()

    assert has_element?(
             view,
             "#sales-bills-send-error",
             "Choose an existing Tally party for INV-001 before sending."
           )

    assert has_element?(view, "#sales-bill-delivery-INV-001", "Needs review")

    {:ok, view, _html} =
      view
      |> element("#sales-bills-voucher-table a[href$='?item=INV-001']")
      |> render_click()
      |> follow_redirect(conn)

    assert has_element?(view, "#sales-bill-posting-review[data-variant='workbench']")
    assert has_element?(view, "#sales-bill-tally-posting-form")
    assert has_element?(view, "#sales-bill-posting-review", company.name)
    assert has_element?(view, "#tally_posting_party_ledger_identity")
    assert has_element?(view, "#sales-bill-evidence-frame")
    assert has_element?(view, "#sales-bill-proposed-voucher", "Sales invoice")
    assert has_element?(view, "#sales-bill-proposed-voucher", "Tally · #{company.name}")
    assert has_element?(view, "#sales-bill-invoice-facts")
    assert has_element?(view, "#sales-bill-party-mapping", "Tally party ledger")
    assert has_element?(view, "#sales-bill-tax-posting", "Tax ledgers")
    assert has_element?(view, "#sales-bill-mappings-remaining", "required")
    assert has_element?(view, "#sales-bill-invoice-identity", "INV-001")
    assert has_element?(view, "#sales-bill-buyer-identity", "Customer & Co")
    assert has_element?(view, "#sales-bill-edit-invoice-facts", "Edit invoice facts")
    refute has_element?(view, "label[for='tally-posting-invoice-number']")
    assert has_element?(view, "#tally-posting-invoice-number-value[value='INV-001']")
    assert has_element?(view, "#sales-bill-line-summary-0", "Technical support services")
    assert has_element?(view, "#sales-bill-line-summary-0", "HSN 998719")
    refute has_element?(view, "#sales-bill-line-edit-sheet")

    view |> element("#sales-bill-edit-invoice-facts") |> render_click()

    assert has_element?(view, "#sales-bill-invoice-facts-sheet[data-variant='sheet']")
    assert has_element?(view, "label[for='invoice_facts_invoice_number']", "Invoice number")
    assert has_element?(view, "#invoice_facts_invoice_number[value='INV-001']")

    view |> element("#sales-bill-invoice-facts-sheet button", "Cancel") |> render_click()

    assert has_element?(view, "#sales-bill-invoice-identity", "INV-001")
    refute has_element?(view, "#sales-bill-invoice-facts-sheet")

    assert has_element?(view, "#sales-bill-narration-value", "Imported from Nila")
    refute has_element?(view, "#tally-posting-narration")

    view |> element("#sales-bill-edit-narration") |> render_click()
    assert has_element?(view, "#tally-posting-narration")
    view |> element("#sales-bill-finish-narration") |> render_click()
    refute has_element?(view, "#tally-posting-narration")

    view
    |> element("#sales-bill-edit-line-0")
    |> render_click()

    assert has_element?(view, "#sales-bill-line-edit-sheet[data-variant='sheet']")
    assert has_element?(view, "#line_edit_description[value='Technical support services']")
    assert has_element?(view, "#line_edit_hsn_sac[value='998719']")
    assert has_element?(view, "#sales-bill-line-edit-form")
    assert has_element?(view, "button[form='sales-bill-line-edit-form']", "Save changes")
    assert has_element?(view, "#tally-posting-line-sales-ledger-0")
    assert has_element?(view, "#sales-bill-place-of-supply", "Karnataka")
    assert has_element?(view, "#tally-posting-place-of-supply-value[value='29']")
    assert has_element?(view, "#sales-bill-tax-row-igst", "Output IGST")

    assert has_element?(
             view,
             "#sales-bill-next-required-mapping",
             "Choose the Tally party ledger"
           )

    refute has_element?(view, "#sales-bill-save-tally-posting")

    refute has_element?(
             view,
             ".nila-callout[data-kind='warning']",
             "Posting details required"
           )

    view |> element("#sales-bill-evidence-frame-open") |> render_click()
    assert has_element?(view, "#sales-bill-evidence-overlay")
    view |> element("#sales-bill-evidence-overlay-close") |> render_click()
    refute has_element?(view, "#sales-bill-evidence-overlay")

    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0
  end

  test "reviews only invoices with missing posting mappings and saves through the queue", %{
    conn: conn,
    client: client,
    dump: dump,
    company: company
  } do
    Nila.Repo.get_by!(SyncedMaster,
      company_id: company.id,
      kind: "ledger",
      name: "Customer & Co"
    )
    |> Nila.Repo.delete!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    chosen_party =
      Nila.Repo.insert!(%SyncedMaster{
        org_id: company.org_id,
        company_id: company.id,
        kind: "ledger",
        identity: "ledger:chosen-customer",
        name: "Chosen Customer",
        data: %{"parent" => "Sundry Debtors"},
        inserted_at: now,
        updated_at: now
      })

    [first] = dump.invoices

    second =
      first
      |> Map.put("id", "source-inv-002")
      |> Map.put("invoice_number", "INV-002")
      |> Map.put("buyer_name", "Second Customer")
      |> Map.put("buyer_gstin", "29AAACB2894G1ZJ")

    dump =
      dump
      |> Ecto.Changeset.change(invoices: [first, second])
      |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    assert has_element?(view, "#sales-bills-required-mappings", "2 invoices need Tally details")
    assert has_element?(view, "#sales-bills-review-required", "Review 2")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Needs review")
    assert has_element?(view, "#sales-bill-delivery-source-inv-002", "Needs review")
    assert has_element?(view, "#sales-bills-result", "No sales vouchers ready")

    view |> element("#sales-bills-review-required") |> render_click()

    assert has_element?(view, "#sales-bill-posting-review", "Review · 2 invoices left")

    assert has_element?(
             view,
             "#sales-bill-next-required-mapping",
             "Next: Choose the Tally party ledger"
           )

    refute has_element?(view, "#sales-bill-save-tally-posting")

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{"party_ledger_identity" => chosen_party.identity}
    })
    |> render_change()

    assert has_element?(view, "#sales-bill-posting-ready")
    assert has_element?(view, "#sales-bill-save-tally-posting", "Save & next")

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{"party_ledger_identity" => chosen_party.identity}
    })
    |> render_submit()

    assert has_element?(view, "#sales-bill-posting-review", "Invoice INV-002")
    assert has_element?(view, "#sales-bill-posting-review", "Review · 1 invoice left")

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{"party_ledger_identity" => chosen_party.identity}
    })
    |> render_change()

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{"party_ledger_identity" => chosen_party.identity}
    })
    |> render_submit()

    refute has_element?(view, "#sales-bill-posting-review")
    refute has_element?(view, "#sales-bills-required-mappings")
    assert has_element?(view, "#sales-bills-result", "2 sales vouchers ready")
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Ready")
    assert has_element?(view, "#sales-bill-delivery-source-inv-002", "Ready")
  end

  test "an unresolved party does not prevent resolved vouchers from being queued", %{
    conn: conn,
    client: client,
    dump: dump,
    company: company
  } do
    [invoice] = dump.invoices

    unresolved =
      invoice
      |> Map.put("id", "source-unresolved")
      |> Map.put("invoice_number", "INV-002")
      |> Map.put("buyer_name", "New Customer Pvt Ltd")
      |> Map.put("buyer_gstin", "29AAACB2894G1ZJ")

    dump =
      dump
      |> Ecto.Changeset.change(invoices: [invoice, unresolved])
      |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")
    view |> element("#sales-bills-send-to-tally") |> render_click()

    assert has_element?(
             view,
             "#sales-bills-send-error",
             "Choose an existing Tally party for INV-002 before sending."
           )

    assert has_element?(view, "#sales-bill-delivery-source-unresolved", "Needs review")
    assert has_element?(view, "#sales-bills-remainder", "Not added to Tally")
    assert has_element?(view, "#sales-bill-actions-source-unresolved-trigger")

    assert [job] = Nila.Repo.all(Nila.TallyJobs.Job)
    assert job.payload["invoice_number"] == "INV-001"

    {:ok, reopened, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=source-unresolved")

    assert has_element?(reopened, "#sales-bill-delivery-source-unresolved", "Needs review")
    refute has_element?(reopened, "#sales-bill-edit-line-0[disabled]")
    refute has_element?(reopened, "#sales-bill-save-tally-posting[disabled]")
    assert has_element?(reopened, "#sales-bill-posting-review", company.name)
  end

  test "saves the complete proposed posting and closes the workbench", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    batch_ref = TallyPacket.ref([dump])
    base_path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, base_path)

    {:ok, view, _html} =
      view
      |> element("#sales-bills-voucher-table a[href$='?item=INV-001']")
      |> render_click()
      |> follow_redirect(conn)

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst"
      }
    })
    |> render_submit()

    assert_patch(view, base_path)
    refute has_element?(view, "#sales-bill-posting-review")
  end

  test "saves a line correction without sending or losing posting selections", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    batch_ref = TallyPacket.ref([dump])
    path = "/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001"
    {:ok, view, _html} = live(conn, path)

    view
    |> form("#sales-bill-tally-posting-form", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst"
      }
    })
    |> render_change()

    view |> element("#sales-bill-edit-line-0") |> render_click()

    view
    |> form("#sales-bill-line-edit-form", %{
      "line_edit" => %{
        "description" => "Corrected support services",
        "hsn_sac" => "998719",
        "quantity" => "1",
        "uom" => "NOS",
        "rate" => "1000",
        "taxable_value" => "1000",
        "igst_rate" => "18",
        "igst_amount" => "180"
      }
    })
    |> render_submit()

    refute has_element?(view, "#sales-bill-line-edit-sheet")
    assert has_element?(view, "#sales-bill-line-summary-0", "Corrected support services")

    assert has_element?(
             view,
             "#tally_posting_party_ledger_identity option[selected][value='name:customer & co']"
           )

    assert has_element?(
             view,
             "#tally-posting-line-sales-ledger-0 option[selected][value='name:sales']"
           )

    assert has_element?(
             view,
             "#tally_posting_igst_ledger_identity option[selected][value='name:output igst']"
           )

    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0

    {:ok, reopened, _html} = live(conn, path)
    assert has_element?(reopened, "#sales-bill-line-summary-0", "Corrected support services")
  end

  test "shows ordinary decimal values in the line editor", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices
    [line] = invoice["line_items"]

    line =
      Map.merge(line, %{
        "quantity" => 1.0,
        "printed_unit_price" => 3_000.0,
        "taxable_value" => 3_000.0,
        "igst_rate" => 9.0,
        "igst_amount" => 270.0
      })

    dump
    |> Ecto.Changeset.change(invoices: [Map.put(invoice, "line_items", [line])])
    |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])

    {:ok, view, _html} =
      live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001")

    view |> element("#sales-bill-edit-line-0") |> render_click()

    assert has_element?(view, "#line_edit_quantity[value='1.0']")
    assert has_element?(view, "#line_edit_rate[value='3000']")
    assert has_element?(view, "#line_edit_taxable_value[value='3000']")
    assert has_element?(view, "#line_edit_igst_rate[value='9.0']")
    assert has_element?(view, "#line_edit_igst_amount[value='270.0']")
  end

  test "keeps batch navigation inside the selected-item query", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [first] = dump.invoices

    second =
      first
      |> Map.put("id", "second-invoice")
      |> Map.put("invoice_number", "INV-002")

    dump = dump |> Ecto.Changeset.change(invoices: [first, second]) |> Nila.Repo.update!()
    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    {:ok, view, _html} =
      view
      |> element("#sales-bills-voucher-table a[href$='?item=INV-001']")
      |> render_click()
      |> follow_redirect(conn)

    assert has_element?(view, "#sales-bill-posting-previous[disabled]")
    assert has_element?(view, "#sales-bill-posting-next:not([disabled])")
    assert has_element?(view, "#sales-bill-posting-position", "1 of 2")
    assert has_element?(view, "#sales-bill-posting-back", "Back to batch")

    assert has_element?(
             view,
             "#sales-bill-posting-review-keys[phx-hook='NilaWeb.Gst.SalesBillsLive.SalesBillPostingReviewKeys'][data-next-item='second-invoice'][data-navigation-enabled='true']"
           )

    view |> element("#sales-bill-posting-next") |> render_click()

    assert_patch(
      view,
      "/sales-bills/#{client.id}/batch/#{batch_ref}?item=second-invoice"
    )

    assert has_element?(view, "#sales-bill-posting-review", "INV-002")
    assert has_element?(view, "#sales-bill-posting-previous:not([disabled])")
    assert has_element?(view, "#sales-bill-posting-next[disabled]")
    assert has_element?(view, "#sales-bill-posting-position", "2 of 2")

    assert has_element?(
             view,
             "#sales-bill-posting-review-keys[data-previous-item='INV-001']:not([data-next-item])"
           )
  end

  test "saves corrections before sending the whole batch", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device
  } do
    [first] = dump.invoices

    second =
      first
      |> Map.put("id", "second-invoice")
      |> Map.put("invoice_number", "INV-002")

    dump = dump |> Ecto.Changeset.change(invoices: [first, second]) |> Nila.Repo.update!()
    batch_ref = TallyPacket.ref([dump])
    path = "/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001"
    {:ok, view, _html} = live(conn, path)

    render_submit(view, "save-tally-posting", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst",
        "invoice" => %{
          "invoice_number" => "INV-001-A",
          "invoice_date" => "2026-07-16",
          "buyer_name" => "Customer & Company",
          "buyer_gstin" => "29AAVCS8021P1ZB",
          "place_of_supply" => "29",
          "narration" => "Corrected from invoice",
          "line_items" => %{
            "0" => %{
              "description" => "Corrected technical services",
              "hsn_sac" => "998713",
              "quantity" => "2",
              "uom" => "NOS",
              "rate" => "500",
              "taxable_value" => "1000",
              "igst_rate" => "18",
              "igst_amount" => "180"
            }
          }
        }
      }
    })

    assert_patch(view, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")
    refute has_element?(view, "#sales-bill-posting-review")

    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0
    view |> element("#sales-bills-send-to-tally") |> render_click()
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Adding…")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 2
    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert job.payload["invoice_number"] == "INV-001-A"
    assert job.payload["xml"] =~ "<VOUCHERNUMBER>INV-001-A</VOUCHERNUMBER>"
    assert job.payload["xml"] =~ "Corrected technical services"
    assert job.payload["xml"] =~ "<GSTHSNNAME>998713</GSTHSNNAME>"
    assert job.payload["xml"] =~ "<PLACEOFSUPPLY>Karnataka</PLACEOFSUPPLY>"

    assert {:ok, _job} = TallyJobs.complete(device.id, job.id, "succeeded", %{"created" => 1})
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Added")

    {:ok, reopened, _html} = live(conn, path)
    assert has_element?(reopened, "#tally-posting-invoice-number-value[value='INV-001-A']")
    assert has_element?(reopened, "#tally-posting-place-of-supply-value[value='29']")
    assert has_element?(reopened, "#sales-bill-place-of-supply", "Karnataka")
    assert has_element?(reopened, "#sales-bill-line-summary-0", "Corrected technical services")
    assert has_element?(reopened, "#sales-bill-line-summary-0", "HSN 998713")
  end

  test "saves invoice facts in the sheet without losing posting mappings", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001"
    {:ok, view, _html} = live(conn, path)

    render_change(view, "preview-tally-posting", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst",
        "invoice" => %{
          "invoice_number" => "INV-001",
          "invoice_date" => "2026-07-15",
          "buyer_name" => "Customer & Co",
          "buyer_gstin" => "29AAVCS8021P1ZB",
          "place_of_supply" => "29"
        }
      }
    })

    view |> element("#sales-bill-edit-invoice-facts") |> render_click()

    view
    |> form("#sales-bill-invoice-facts-form",
      invoice_facts: %{
        invoice_number: "INV-001-A",
        invoice_date: "2026-07-15",
        buyer_name: "Customer & Company",
        buyer_gstin: "29AAVCS8021P1ZB",
        place_of_supply: "29"
      }
    )
    |> render_submit()

    refute has_element?(view, "#sales-bill-invoice-facts-sheet")
    assert has_element?(view, "#sales-bill-invoice-identity", "INV-001-A · 15 Jul 2026")
    assert has_element?(view, "#sales-bill-buyer-identity", "Customer & Company")
    assert has_element?(view, "#sales-bill-place-of-supply", "Karnataka")

    assert has_element?(
             view,
             "#tally_posting_party_ledger_identity option[selected]",
             "Customer & Co"
           )

    assert has_element?(
             view,
             "#tally-posting-line-sales-ledger-0 option[selected]",
             "Sales"
           )
  end

  test "saves a warning and confirms it at the batch send boundary", %{
    conn: conn,
    client: client,
    dump: dump
  } do
    [invoice] = dump.invoices

    dump =
      dump
      |> Ecto.Changeset.change(invoices: [Map.put(invoice, "printed_grand_total", 1_180)])
      |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    path = "/sales-bills/#{client.id}/batch/#{batch_ref}?item=INV-001"
    {:ok, view, _html} = live(conn, path)

    refute has_element?(
             view,
             ".nila-callout[data-kind='warning']",
             "Invoice total does not match"
           )

    view
    |> element("#sales-bill-edit-line-0")
    |> render_click()

    view
    |> form("#sales-bill-line-edit-form", %{
      "line_edit" => %{
        "description" => "Technical support services",
        "hsn_sac" => "998719",
        "quantity" => "1",
        "uom" => "",
        "rate" => "900",
        "taxable_value" => "900",
        "igst_rate" => "18",
        "igst_amount" => "180"
      }
    })
    |> render_submit()

    refute has_element?(view, "#sales-bill-line-edit-sheet")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0

    assert has_element?(
             view,
             ".nila-callout[data-kind='warning']",
             "The lines calculate to ₹1,080.00; the invoice prints ₹1,180.00."
           )

    render_submit(view, "save-tally-posting", %{
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst"
      }
    })

    assert_patch(view, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    view |> element("#sales-bills-send-to-tally") |> render_click()
    assert has_element?(view, "#sales-bills-tally-warning-dialog", "1 invoice still needs review")

    view |> element("#sales-bills-tally-warning-cancel") |> render_click()
    refute has_element?(view, "#sales-bills-tally-warning-dialog")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 0

    view |> element("#sales-bills-send-to-tally") |> render_click()
    view |> element("#sales-bills-tally-warning-confirm") |> render_click()
    refute has_element?(view, "#sales-bills-send-error")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 1
  end

  test "offers read-only verification before retrying an unknown outcome", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device
  } do
    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    view |> element("#sales-bills-send-to-tally") |> render_click()
    assert {:ok, job} = TallyJobs.claim_next(device.id)

    assert {:ok, _job} =
             TallyJobs.complete(device.id, job.id, "indeterminate", %{"kind" => "Disconnected"})

    assert has_element?(view, "#sales-bill-delivery-INV-001", "Check in Tally")
    assert has_element?(view, "#sales-bills-verify-tally", "Check Tally")
    refute has_element?(view, "#sales-bills-retry-tally")

    view |> element("#sales-bills-verify-tally") |> render_click()

    pending = TallyJobs.get_job!(job.id)
    assert pending.status == "pending"
    assert pending.payload["mode"] == "verify_only"
  end

  test "offers an idempotent Tally check after successful delivery", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device
  } do
    batch_ref = TallyPacket.ref([dump])
    {:ok, view, _html} = live(conn, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")

    view |> element("#sales-bills-send-to-tally") |> render_click()
    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert {:ok, _job} = TallyJobs.complete(device.id, job.id, "succeeded", %{"master_id" => 42})

    assert has_element?(view, "#sales-bills-ensure-tally", "Check Tally")
    view |> element("#sales-bills-ensure-tally") |> render_click()

    pending = TallyJobs.get_job!(job.id)
    assert pending.status == "pending"
    refute Map.has_key?(pending.payload, "mode")
  end

  test "counts invoices without jobs as not added and can enqueue the remainder", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device
  } do
    [invoice] = dump.invoices
    second_invoice = Map.put(invoice, "invoice_number", "INV-002")

    dump =
      dump |> Ecto.Changeset.change(invoices: [invoice, second_invoice]) |> Nila.Repo.update!()

    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    view |> element("#sales-bills-send-to-tally") |> render_click()

    [first_job, second_job] = Nila.Repo.all(Nila.TallyJobs.Job)

    assert {:ok, running} = TallyJobs.claim_next(device.id)
    assert running.id == first_job.id

    assert {:ok, _done} =
             TallyJobs.complete(device.id, first_job.id, "succeeded", %{"master_id" => 42})

    Nila.Repo.delete!(second_job)
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#sales-bills-partial-tally-result", "1 of 2 added to Tally")
    assert has_element?(view, "#sales-bills-retry-tally", "Try again")
    assert render(view) =~ "INV-002"

    view |> element("#sales-bills-retry-tally") |> render_click()

    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 2
  end

  defp sync_demo_masters(org_id, company_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Nila.Repo.insert!(%SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "voucher_type",
      identity: "name:sales",
      name: "Sales",
      data: %{"numbering_method" => "Manual"},
      inserted_at: now,
      updated_at: now
    })

    Enum.each(["Customer & Co", "Sales", "Output IGST"], fn name ->
      parent =
        case name do
          "Customer & Co" -> "Sundry Debtors"
          "Sales" -> "Sales Accounts"
          "Output IGST" -> "Duties & Taxes"
        end

      Nila.Repo.insert!(%SyncedMaster{
        org_id: org_id,
        company_id: company_id,
        kind: "ledger",
        identity: "name:" <> String.downcase(name),
        name: name,
        data:
          if(name == "Output IGST",
            do: %{
              "parent" => parent,
              "tax_type" => "GST",
              "gst_duty_head" => "Integrated Tax"
            },
            else: %{"parent" => parent}
          ),
        inserted_at: now,
        updated_at: now
      })
    end)
  end
end
