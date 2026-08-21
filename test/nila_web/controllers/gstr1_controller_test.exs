defmodule NilaWeb.Gstr1ControllerTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoff
  alias Nila.Gst.Sales.{Gstr1, Months}
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyJobs.Job

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze & Tech",
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
              "taxable_value" => 1000,
              "igst_rate" => 18,
              "igst_amount" => 180
            }
          ],
          "printed_total_taxable" => 1000,
          "printed_total_tax" => 180,
          "printed_grand_total" => 1180
        }
      })

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-07",
        state: "worked",
        invoices: [invoice],
        issues: Gstr1.validation_issues([invoice]),
        derived_gstr1: Gstr1.derive([invoice], Gstr1.production_header(client.gstin, "2026-07"))
      })

    %{conn: log_in_user(conn, user), client: client, month: month, user: user, org: org}
  end

  test "downloads an unsigned month's current B2B workings as a Winman workbook", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/winman-b2b.xlsm")

    assert response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "application/vnd.ms-excel.sheet.macroEnabled.12"
           ]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "gstr1_#{client.gstin}_2026-07_winman_b2b.xlsm"

    sheet = conn.resp_body |> entries() |> Map.fetch!("xl/worksheets/sheet2.xml")
    assert sheet =~ "INV-001"
    assert sheet =~ "Customer &amp; Co"
    assert sheet =~ "Karnataka"
    assert sheet =~ ~s(<c r="H6" s="97"><v>180.0</v></c>)
  end

  test "downloads the frozen projection after approval", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    frozen_derived =
      put_in(
        month.derived_gstr1,
        ["b2b", Access.at(0), "inv", Access.at(0), "inum"],
        "FROZEN-001"
      )

    frozen_invoices = [
      month.invoices
      |> hd()
      |> Map.put("invoice_number", "FROZEN-001")
      |> Map.put("buyer_name", "Frozen Customer")
    ]

    %Signoff{
      org_id: org.id,
      sales_month_id: month.id,
      signed_by_id: user.id
    }
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => frozen_derived, "invoices" => frozen_invoices}
    })
    |> Repo.insert!()

    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/winman-b2b.xlsm")
    sheet = conn.resp_body |> entries() |> Map.fetch!("xl/worksheets/sheet2.xml")

    assert sheet =~ "FROZEN-001"
    assert sheet =~ "Frozen Customer"
    refute sheet =~ ">INV-001<"
    refute sheet =~ "Customer &amp; Co"
  end

  test "downloads current sales workings as Tally XML", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/tally.xml")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "sales_#{client.gstin}_2026-07_tally.xml"

    assert conn.resp_body =~ "<TALLYREQUEST>Import</TALLYREQUEST>"
    assert conn.resp_body =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"
    assert conn.resp_body =~ "<LEDGERNAME>Customer &amp; Co</LEDGERNAME>"
    assert conn.resp_body =~ "<LEDGERNAME>Output IGST</LEDGERNAME>"
    assert conn.resp_body =~ "<AMOUNT>180.00</AMOUNT>"
  end

  test "downloads the frozen sales projection as Tally XML", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    frozen_invoice =
      month.invoices
      |> hd()
      |> Map.put("invoice_number", "FROZEN-TALLY-001")
      |> Map.put("buyer_name", "Frozen Tally Customer")

    %Signoff{
      org_id: org.id,
      sales_month_id: month.id,
      signed_by_id: user.id
    }
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => month.derived_gstr1, "invoices" => [frozen_invoice]}
    })
    |> Repo.insert!()

    conn = get(conn, ~p"/gstr1/#{client.id}/2026-07/tally.xml")

    assert conn.resp_body =~ "FROZEN-TALLY-001"
    assert conn.resp_body =~ "Frozen Tally Customer"
    refute conn.resp_body =~ "INV-001"
    refute conn.resp_body =~ "Customer &amp; Co"
  end

  test "queues the approved sales vouchers for a selected connector company", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    %Signoff{
      org_id: org.id,
      sales_month_id: month.id,
      signed_by_id: user.id
    }
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => month.derived_gstr1, "invoices" => month.invoices}
    })
    |> Repo.insert!()

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{
          "name" => "Nila",
          "tally_guid" => "company-nila",
          "gstin" => client.gstin
        }
      ])

    company
    |> Ecto.Changeset.change(client_id: client.id)
    |> Repo.update!()

    seed_ledgers(company, ["Customer & Co", "Sales", "Output IGST"])
    seed_voucher_type(company, "Sales", "Manual")

    conn =
      post(conn, ~p"/gstr1/#{client.id}/2026-07/tally", %{
        "tally" => %{"company_id" => Integer.to_string(company.id)}
      })

    assert redirected_to(conn) == ~p"/gst/#{client.id}/2026-07"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Queued 1 sales voucher for Nila"

    assert job = Repo.one!(Job)
    assert job.kind == "import_vouchers"
    assert job.status == "pending"
    assert job.payload["company"] == "Nila"
    assert job.payload["expected_count"] == 1
    assert job.payload["xml"] =~ "<SVCURRENTCOMPANY>Nila</SVCURRENTCOMPANY>"
    assert job.payload["xml"] =~ "<ISINVOICE>Yes</ISINVOICE>"
    assert job.payload["xml"] =~ "<PARTYGSTIN>29AAVCS8021P1ZB</PARTYGSTIN>"
    assert job.payload["xml"] =~ "<GSTHSNNAME>998719</GSTHSNNAME>"

    _repeated =
      post(recycle(conn), ~p"/gstr1/#{client.id}/2026-07/tally", %{
        "tally" => %{"company_id" => Integer.to_string(company.id)}
      })

    assert Repo.aggregate(Job, :count) == 1
  end

  test "blocks a voucher before Tally when a referenced ledger is missing", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    %Signoff{org_id: org.id, sales_month_id: month.id, signed_by_id: user.id}
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => month.derived_gstr1, "invoices" => month.invoices}
    })
    |> Repo.insert!()

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{
          "name" => "Nila",
          "tally_guid" => "company-nila",
          "gstin" => client.gstin
        }
      ])

    company
    |> Ecto.Changeset.change(client_id: client.id)
    |> Repo.update!()

    seed_ledgers(company, ["Sales", "Output IGST"])

    conn =
      post(conn, ~p"/gstr1/#{client.id}/2026-07/tally", %{
        "tally" => %{"company_id" => Integer.to_string(company.id)}
      })

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
             "Held back 1 voucher (INV-001)"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Customer & Co"

    assert Repo.aggregate(Job, :count) == 0
  end

  test "blocks GST vouchers when the linked Tally company has no GST registration", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    %Signoff{org_id: org.id, sales_month_id: month.id, signed_by_id: user.id}
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => month.derived_gstr1, "invoices" => month.invoices}
    })
    |> Repo.insert!()

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Nila", "tally_guid" => "company-nila"}
      ])

    company
    |> Ecto.Changeset.change(client_id: client.id)
    |> Repo.update!()

    conn =
      post(conn, ~p"/gstr1/#{client.id}/2026-07/tally", %{
        "tally" => %{"company_id" => Integer.to_string(company.id)}
      })

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "has no GSTIN"
    assert Repo.aggregate(Job, :count) == 0
  end

  test "does not send a client's sales to another client's linked Tally company", %{
    conn: conn,
    client: client,
    month: month,
    org: org,
    user: user
  } do
    %Signoff{org_id: org.id, sales_month_id: month.id, signed_by_id: user.id}
    |> Signoff.changeset(%{
      artifact: "gstr1",
      snapshot: %{"derived" => month.derived_gstr1, "invoices" => month.invoices}
    })
    |> Repo.insert!()

    {:ok, other_client} =
      Clients.create_client(%{org_id: org.id, name: "Another Client", type: "company"})

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{"name" => "Another Client", "tally_guid" => "company-another-client"}
      ])

    company
    |> Ecto.Changeset.change(client_id: other_client.id)
    |> Repo.update!()

    conn =
      post(conn, ~p"/gstr1/#{client.id}/2026-07/tally", %{
        "tally" => %{"company_id" => Integer.to_string(company.id)}
      })

    assert redirected_to(conn) == ~p"/gst/#{client.id}/2026-07"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
    assert Repo.aggregate(Job, :count) == 0
  end

  test "does not expose another organisation's workbook", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> get(~p"/gstr1/#{client.id}/2026-07/winman-b2b.xlsm")

    assert response(conn, 404) == "Not found"
  end

  test "does not expose another organisation's Tally XML", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> get(~p"/gstr1/#{client.id}/2026-07/tally.xml")

    assert response(conn, 404) == "Not found"
  end

  test "does not send another organisation's sales to Tally", %{client: client} do
    %{user: outsider} = user_with_org_fixture()

    conn =
      build_conn()
      |> log_in_user(outsider)
      |> post(~p"/gstr1/#{client.id}/2026-07/tally")

    assert response(conn, 404) == "Not found"
  end

  test "does not let an operator write to Tally", %{client: client} do
    %{user: operator} = user_with_org_fixture(%{role: "member"})

    conn =
      build_conn()
      |> log_in_user(operator)
      |> post(~p"/gstr1/#{client.id}/2026-07/tally")

    assert redirected_to(conn) == ~p"/sales-bills"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You don't have access to that area."
  end

  defp entries(workbook) do
    {:ok, entries} = :zip.extract(workbook, [:memory])
    Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
  end

  defp seed_ledgers(company, names) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(names, fn name ->
        %{
          org_id: company.org_id,
          company_id: company.id,
          kind: "ledger",
          identity: String.downcase(name),
          name: name,
          data: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(SyncedMaster, rows)
    assert count == length(rows)
  end

  defp seed_voucher_type(company, name, numbering_method) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%SyncedMaster{
      org_id: company.org_id,
      company_id: company.id,
      kind: "voucher_type",
      identity: "name:#{String.downcase(name)}",
      name: name,
      data: %{"numbering_method" => numbering_method},
      inserted_at: now,
      updated_at: now
    })
  end
end
