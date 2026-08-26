defmodule NilaWeb.Gst.SalesBillsLiveTest do
  use NilaWeb.ConnCase, async: true

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

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Nila.Repo.insert!(%SyncedMaster{
      org_id: org.id,
      company_id: company.id,
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
        org_id: org.id,
        company_id: company.id,
        kind: "ledger",
        identity: "name:" <> String.downcase(name),
        name: name,
        data: %{"parent" => parent},
        inserted_at: now,
        updated_at: now
      })
    end)

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
    refute has_element?(view, "#sales-bills-voucher-table")

    assert has_element?(
             view,
             "#sales-bills-needs-review",
             ~s(place of supply "Chennai" is not a known GST state code)
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

  test "removes an invoice from Nila without touching its source or Tally voucher", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device,
    org: org
  } do
    batch_ref = TallyPacket.ref([dump])
    path = ~p"/sales-bills/#{client.id}/batch/#{batch_ref}"
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#sales-bill-actions-INV-001-trigger[aria-label]")

    view |> element("#sales-bill-remove-INV-001") |> render_click()

    assert has_element?(view, "#sales-bill-remove-dialog", "Remove invoice?")

    assert has_element?(
             view,
             "#sales-bill-remove-dialog",
             "It won’t affect anything already added to Tally."
           )

    view |> element("#sales-bill-remove-cancel") |> render_click()
    refute has_element?(view, "#sales-bill-remove-dialog")

    view |> element("#sales-bills-send-to-tally") |> render_click()
    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert {:ok, job} = TallyJobs.complete(device.id, job.id, "succeeded", %{"created" => 1})

    view |> element("#sales-bill-remove-INV-001") |> render_click()
    view |> element("#sales-bill-remove-confirm") |> render_click()

    assert has_element?(view, "#sales-bills-result", "No sales vouchers ready")
    refute has_element?(view, "#sales-bills-voucher-table")
    refute has_element?(view, "#sales-bill-remove-dialog")

    removal = Nila.Repo.one!(InvoiceRemoval)
    assert removal.org_id == org.id
    assert removal.client_id == client.id
    assert removal.batch_ref == batch_ref
    assert removal.source_id == "INV-001"
    assert removal.removed_at

    assert [source_invoice] = Nila.Repo.reload!(dump).invoices
    assert source_invoice["invoice_number"] == "INV-001"
    assert TallyJobs.get_job!(job.id).status == "succeeded"

    {:ok, reopened, _html} = live(conn, path)
    assert has_element?(reopened, "#sales-bills-result", "No sales vouchers ready")
    refute has_element?(reopened, "#sales-bills-voucher-table")
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
    assert has_element?(view, "#sales-bill-proposed-voucher", "Proposed Tally voucher")
    assert has_element?(view, "#sales-bill-proposed-voucher", "Sales")
    assert has_element?(view, "#tally-posting-invoice-number[value='INV-001']")
    assert has_element?(view, "#sales-bill-line-summary-0", "Technical support services")
    assert has_element?(view, "#sales-bill-line-summary-0", "HSN 998719")
    refute has_element?(view, "#sales-bill-line-edit-sheet")

    view
    |> element("#sales-bill-edit-line-0")
    |> render_click()

    assert has_element?(view, "#sales-bill-line-edit-sheet[data-variant='sheet']")
    assert has_element?(view, "#line_edit_description[value='Technical support services']")
    assert has_element?(view, "#line_edit_hsn_sac[value='998719']")
    assert has_element?(view, "#sales-bill-line-edit-form")
    assert has_element?(view, "button[form='sales-bill-line-edit-form']", "Save changes")
    assert has_element?(view, "#tally-posting-line-sales-ledger-0")
    assert has_element?(view, "#tally-posting-place-of-supply option[selected][value='29']")
    assert has_element?(view, "#sales-bill-tax-row-igst", "Output IGST")
    assert has_element?(view, "#sales-bill-save-tally-posting", "Save & Close")

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

    view |> element("#sales-bill-posting-next") |> render_click()

    assert_patch(
      view,
      "/sales-bills/#{client.id}/batch/#{batch_ref}?item=second-invoice"
    )

    assert has_element?(view, "#sales-bill-posting-review", "INV-002")
    assert has_element?(view, "#sales-bill-posting-previous:not([disabled])")
    assert has_element?(view, "#sales-bill-posting-next[disabled]")
    assert has_element?(view, "#sales-bill-posting-position", "2 of 2")
  end

  test "saves corrections and syncs only the selected invoice", %{
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
      "tally_action" => "sync",
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst",
        "invoice" => %{
          "invoice_number" => "INV-001-A",
          "invoice_date" => "2026-07-16",
          "buyer_name" => "Customer & Company",
          "buyer_gstin" => "29AAVCS8021P1ZB",
          "place_of_supply" => "33",
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
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Adding…")
    assert Nila.Repo.aggregate(Nila.TallyJobs.Job, :count) == 1
    assert {:ok, job} = TallyJobs.claim_next(device.id)
    assert job.payload["invoice_number"] == "INV-001-A"
    assert job.payload["xml"] =~ "<VOUCHERNUMBER>INV-001-A</VOUCHERNUMBER>"
    assert job.payload["xml"] =~ "Corrected technical services"
    assert job.payload["xml"] =~ "<GSTHSNNAME>998713</GSTHSNNAME>"
    assert job.payload["xml"] =~ "<PLACEOFSUPPLY>Tamil Nadu</PLACEOFSUPPLY>"

    assert {:ok, _job} = TallyJobs.complete(device.id, job.id, "succeeded", %{"created" => 1})
    assert has_element?(view, "#sales-bill-delivery-INV-001", "Added")

    {:ok, reopened, _html} = live(conn, path)
    assert has_element?(reopened, "#tally-posting-invoice-number[value='INV-001-A']")
    assert has_element?(reopened, "#tally-posting-place-of-supply option[selected][value='33']")
    assert has_element?(reopened, "#sales-bill-line-summary-0", "Corrected technical services")
    assert has_element?(reopened, "#sales-bill-line-summary-0", "HSN 998713")
  end

  test "warns about a printed-total mismatch without blocking sync", %{
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

    refute has_element?(view, "#sales-bill-save-and-sync[disabled]")

    render_submit(view, "save-tally-posting", %{
      "tally_action" => "sync",
      "tally_posting" => %{
        "party_ledger_identity" => "name:customer & co",
        "line_sales_ledger_identities" => %{"0" => "name:sales"},
        "igst_ledger_identity" => "name:output igst"
      }
    })

    assert_patch(view, ~p"/sales-bills/#{client.id}/batch/#{batch_ref}")
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
end
