defmodule Nila.Gst.Sales.InvoiceCorrectionsTest do
  use Nila.DataCase, async: true

  alias Nila.Clients
  alias Nila.Accounts.User
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{InvoiceCorrection, InvoiceCorrections, TallyPacket}
  alias Nila.Orgs.Org
  alias Nila.Orgs.Membership
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyMappings.{PartyMapping, PostingProfile, SalesLineMapping}

  setup do
    org = org_fixture()
    user = user_fixture(org)

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    invoice = invoice_fixture()

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2026-07",
          kind: "sales",
          status: "extracted",
          invoices: [invoice]
        }
      )

    %{
      org: org,
      user: user,
      client: client,
      dump: dump,
      invoice: invoice,
      batch_ref: TallyPacket.ref([dump])
    }
  end

  test "atomically overlays every posting correction while preserving pristine extraction", ctx do
    changes = %{
      "voucher_number" => "INV-001-A",
      "voucher_date" => "16/07/2026",
      "buyer_name" => "Correct Customer Pvt Ltd",
      "buyer_gstin" => "29AAVCS8021P1ZB",
      "narration" => "PO 4455",
      "line_items" => %{
        "0" => %{
          "item_name" => "Annual support",
          "description" => "Annual technical support",
          "hsn_sac" => "998713",
          "quantity" => "2",
          "unit" => "NOS",
          "rate" => "600",
          "taxable_amount" => "1200",
          "cgst_rate" => "0",
          "cgst_amount" => "0",
          "sgst_rate" => "0",
          "sgst_amount" => "0",
          "igst_rate" => "18",
          "igst_amount" => "216"
        }
      }
    }

    assert {:ok, %{invoice: effective, corrections: corrections}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               changes,
               ctx.user.id
             )

    assert length(corrections) == 15
    assert Enum.all?(corrections, &(&1.corrected_by_id == ctx.user.id))
    assert effective["invoice_number"] == "INV-001-A"
    assert effective["invoice_date"] == ~D[2026-07-16]
    assert effective["buyer_name"] == "Correct Customer Pvt Ltd"
    assert effective["narration"] == "PO 4455"

    [line] = effective["line_items"]
    assert line["uom"] == "NOS"
    assert line["printed_unit_price"] == 600.0
    assert line["taxable_value"] == 1200.0
    assert line["cgst_amount"] == 0.0
    assert line["igst_amount"] == 216.0

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])
    assert hd(packet.invoices)["invoice_number"] == "INV-001-A"
    assert hd(packet.invoices)["line_items"] == effective["line_items"]

    [pristine] = Repo.reload!(ctx.dump).invoices
    assert pristine["invoice_number"] == "INV-001"
    assert get_in(pristine, ["line_items", Access.at(0), "description"]) == "Technical support"
  end

  test "packet XML is built from effective corrections rather than pristine invoice data", ctx do
    assert {:ok, _saved} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"invoice_number" => "INV-CORRECTED"}
             )

    assert {:ok, xml} = TallyPacket.build_xml([Repo.reload!(ctx.dump)])
    assert xml =~ "<VOUCHERNUMBER>INV-CORRECTED</VOUCHERNUMBER>"
    refute xml =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"
  end

  test "canonicalizes a corrected place of supply and keeps it after reload", ctx do
    assert {:ok, %{invoice: effective}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"place_of_supply" => "Tamil Nadu"}
             )

    assert effective["place_of_supply"] == "33"
    assert hd(TallyPacket.prepare([Repo.reload!(ctx.dump)]).invoices)["place_of_supply"] == "33"

    assert {:error, {:invalid_correction, "place_of_supply", :invalid_place_of_supply}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"place_of_supply" => "Atlantis"}
             )
  end

  test "holds an unexportable invoice with its structured issue until corrected", ctx do
    invalid_invoice = Map.put(ctx.invoice, "place_of_supply", "Chennai")

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invalid_invoice])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert packet.invoices == []
    assert [held] = packet.needs_review
    assert held.invoice["invoice_number"] == "INV-001"

    assert [%{"code" => "invalid_place_of_supply", "fields" => ["place_of_supply"]}] =
             held.issues

    assert {:ok, %{invoice: corrected}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"place_of_supply" => "Karnataka"},
               ctx.user.id
             )

    assert corrected["place_of_supply"] == "29"

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])
    assert [ready] = packet.invoices
    assert ready["place_of_supply"] == "29"
    assert packet.needs_review == []
  end

  test "saves one complete invoice workbench submission atomically", ctx do
    company = company_fixture(ctx.org, "Nila")
    party = ledger_fixture(ctx.org.id, company.id, "party", "Customer AP", %{})

    sales =
      ledger_fixture(ctx.org.id, company.id, "material-sales", "Material Sales", %{
        "parent" => "Sales Accounts"
      })

    assert {:ok, result} =
             InvoiceCorrections.save_workbench(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               company.id,
               %{
                 invoice: %{
                   "invoice_number" => "INV-WORKBENCH",
                   "place_of_supply" => "Tamil Nadu"
                 },
                 party_ledger_identity: party.identity,
                 posting_profile: %{sales_ledger_identity: sales.identity},
                 line_sales_ledger_identities: %{"0" => sales.identity}
               },
               ctx.user.id
             )

    assert result.invoice["invoice_number"] == "INV-WORKBENCH"
    assert result.invoice["place_of_supply"] == "33"
    assert result.party_mapping.ledger_identity == party.identity
    assert result.posting_profile.sales_ledger_identity == sales.identity
    assert [%SalesLineMapping{ledger_identity: "material-sales"}] = result.line_mappings
  end

  test "rolls back corrections and every mapping when any line ledger is invalid", ctx do
    company = company_fixture(ctx.org, "Nila")
    party = ledger_fixture(ctx.org.id, company.id, "party", "Customer AP", %{})

    sales =
      ledger_fixture(ctx.org.id, company.id, "material-sales", "Material Sales", %{
        "parent" => "Sales Accounts"
      })

    tax = ledger_fixture(ctx.org.id, company.id, "output-igst", "Output IGST", %{})

    assert {:error, {:sales_ledger_not_found, 0}} =
             InvoiceCorrections.save_workbench(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               company.id,
               %{
                 invoice: %{"invoice_number" => "MUST-ROLL-BACK"},
                 party_ledger_identity: party.identity,
                 posting_profile: %{sales_ledger_identity: sales.identity},
                 line_sales_ledger_identities: %{"0" => tax.identity}
               },
               ctx.user.id
             )

    assert Repo.aggregate(InvoiceCorrection, :count) == 0
    assert Repo.aggregate(PartyMapping, :count) == 0
    assert Repo.aggregate(PostingProfile, :count) == 0
    assert Repo.aggregate(SalesLineMapping, :count) == 0
  end

  test "latest append-only event wins and records its prior effective value", ctx do
    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{buyer_name: "First correction"}
             )

    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{buyer_name: "Final correction"}
             )

    [first, second] =
      InvoiceCorrections.list(ctx.org.id, ctx.client.id, ctx.batch_ref, "source-1")

    assert first.payload == %{"from" => "Customer & Co", "to" => "First correction"}
    assert second.payload == %{"from" => "First correction", "to" => "Final correction"}

    [effective] =
      InvoiceCorrections.apply(ctx.org.id, ctx.client.id, ctx.batch_ref, [ctx.invoice])

    assert effective["buyer_name"] == "Final correction"
  end

  test "invalid fields and values roll back the whole correction set", ctx do
    assert {:error, {:invalid_correction, "line_items[0].quantity", :invalid_number}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{
                 "buyer_name" => "Must not persist",
                 "line_items[0].quantity" => "twelve"
               }
             )

    assert Repo.aggregate(InvoiceCorrection, :count) == 0
    assert hd(TallyPacket.prepare([ctx.dump]).invoices)["buyer_name"] == "Customer & Co"

    assert {:error, {:invalid_correction, "bank_account", :unsupported_field}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"bank_account" => "wrong scope"}
             )
  end

  test "org, client, batch, and source boundaries are enforced", ctx do
    other_org = org_fixture()

    assert {:error, :not_found} =
             InvoiceCorrections.save(
               other_org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{buyer_name: "Cross tenant"}
             )

    assert {:error, :not_found} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               "999999999",
               "source-1",
               %{buyer_name: "Wrong batch"}
             )

    assert {:error, :source_not_found} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "missing-source",
               %{buyer_name: "Wrong invoice"}
             )
  end

  defp org_fixture do
    %Org{}
    |> Org.changeset(%{name: "Org #{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp user_fixture(org) do
    user =
      %User{}
      |> User.changeset(%{
        name: "Reviewer",
        email: "reviewer-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert!()

    %Membership{}
    |> Membership.changeset(%{org_id: org.id, user_id: user.id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp company_fixture(org, name) do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "#{name} Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => name}])
    company
  end

  defp ledger_fixture(org_id, company_id, identity, name, data) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "ledger",
      identity: identity,
      name: name,
      data: data,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp invoice_fixture do
    %{
      "id" => "source-1",
      "document_type" => "invoice",
      "document_status" => "active",
      "supply_type" => "taxable",
      "recipient_registration" => "registered",
      "place_of_supply" => "29",
      "invoice_number" => "INV-001",
      "invoice_date" => ~D[2026-07-15],
      "seller_gstin" => "33AEWPH4158J1Z3",
      "buyer_name" => "Customer & Co",
      "buyer_gstin" => "29AAVCS8021P1ZB",
      "line_items" => [
        %{
          "description" => "Technical support",
          "hsn_sac" => "998719",
          "quantity" => 1,
          "uom" => "NOS",
          "printed_unit_price" => 1_000,
          "taxable_value" => 1_000,
          "igst_rate" => 18,
          "igst_amount" => 180
        }
      ]
    }
  end
end
