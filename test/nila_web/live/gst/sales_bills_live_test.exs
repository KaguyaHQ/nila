defmodule NilaWeb.Gst.SalesBillsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Gstr1, TallyPacket}
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyJobs

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
      Nila.Repo.insert!(%SyncedMaster{
        org_id: org.id,
        company_id: company.id,
        kind: "ledger",
        identity: "name:" <> String.downcase(name),
        name: name,
        data: %{},
        inserted_at: now,
        updated_at: now
      })
    end)

    %{
      conn: log_in_user(conn, user),
      client: client,
      dump: dump,
      device: device,
      company: company
    }
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

  test "queues creation details when the registered party ledger is missing", %{
    conn: conn,
    client: client,
    dump: dump,
    device: device,
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

    assert {:ok, job} = TallyJobs.claim_next(device.id)

    assert job.payload["party_ledger"] == %{
             "name" => "Customer & Co",
             "parent" => "Sundry Debtors",
             "gstin" => "29AAVCS8021P1ZB",
             "registration_type" => "Regular",
             "state" => "Karnataka",
             "country" => "India"
           }
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
