defmodule Nila.Gst.Sales.InvoiceCorrectionsTest do
  use Nila.DataCase, async: true

  alias Nila.Clients
  alias Nila.Accounts.User
  alias Nila.Gst.Intake.Dumps

  alias Nila.Gst.Sales.{
    Batch,
    InvoiceCorrection,
    InvoiceCorrections,
    Month,
    Resolutions,
    TallyPacket
  }

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

  test "printed totals persist independently of invoice lines and pristine extraction", ctx do
    pristine = Repo.get!(Nila.Gst.Intake.Dump, ctx.dump.id).invoices

    changes = %{
      "printed_total_taxable" => "1,000.00",
      "printed_total_tax" => "180.00",
      "printed_grand_total" => "1180.00"
    }

    assert {:ok, %{invoice: effective}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               changes,
               ctx.user.id
             )

    assert effective["printed_total_taxable"] == 1000.0
    assert effective["printed_total_tax"] == 180.0
    assert effective["printed_grand_total"] == 1180.0
    assert effective["line_items"] == ctx.invoice["line_items"]
    assert Repo.get!(Nila.Gst.Intake.Dump, ctx.dump.id).invoices == pristine
    [reloaded] = InvoiceCorrections.apply_sources(ctx.org.id, ctx.client.id, [ctx.invoice])
    assert Map.take(reloaded, Map.keys(changes)) == Map.take(effective, Map.keys(changes))
  end

  test "printed totals reject invalid values atomically and distinguish blank from zero", ctx do
    for bad <- ["-1", "not a number"] do
      assert {:error, {:invalid_correction, "printed_grand_total", :invalid_number}} =
               InvoiceCorrections.save(
                 ctx.org.id,
                 ctx.client.id,
                 ctx.batch_ref,
                 "source-1",
                 %{"printed_total_taxable" => "900", "printed_grand_total" => bad},
                 ctx.user.id
               )

      assert InvoiceCorrections.list(ctx.org.id, ctx.client.id, "source-1") == []
    end

    assert {:ok, %{invoice: effective}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"printed_total_tax" => "0", "printed_grand_total" => ""},
               ctx.user.id
             )

    assert effective["printed_total_tax"] == 0.0
    assert effective["printed_grand_total"] == nil
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

  test "keeps a legacy place-of-supply correction without gating Tally", ctx do
    assert {:ok, %{invoice: effective}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"place_of_supply" => "Tamil Nadu"}
             )

    assert effective["place_of_supply"] == "33"
    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])
    assert hd(packet.all_invoices)["place_of_supply"] == "33"
    assert [sendable] = packet.invoices
    assert sendable["place_of_supply"] == "33"
    assert packet.warnings == []
    assert packet.blocked == []
    assert {:ok, xml} = TallyPacket.build_xml([Repo.reload!(ctx.dump)])
    refute xml =~ "<PLACEOFSUPPLY>"

    assert {:error, {:invalid_correction, "place_of_supply", :invalid_place_of_supply}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"place_of_supply" => "Atlantis"}
             )
  end

  test "does not require place of supply when correcting an unrelated invoice fact", ctx do
    invoice_without_pos = Map.put(ctx.invoice, "place_of_supply", nil)

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invoice_without_pos])
    |> Repo.update!()

    assert {:ok, %{invoice: corrected}} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{"invoice_number" => "INV-001-A", "place_of_supply" => ""},
               ctx.user.id
             )

    assert corrected["invoice_number"] == "INV-001-A"
    assert corrected["place_of_supply"] == nil
  end

  test "ignores an invalid legacy place of supply when preparing Tally", ctx do
    invalid_invoice = Map.put(ctx.invoice, "place_of_supply", "Chennai")

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invalid_invoice])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert [ready] = packet.invoices
    assert ready["place_of_supply"] == "Chennai"
    assert packet.needs_review == []
    assert {:ok, xml} = TallyPacket.build_xml([Repo.reload!(ctx.dump)])
    refute xml =~ "<PLACEOFSUPPLY>"
  end

  test "keeps a serializer-valid invoice sendable when readiness finds an amount warning", ctx do
    invalid_invoice = Map.put(ctx.invoice, "printed_total_taxable", 900)

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invalid_invoice])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert [sendable] = packet.invoices
    assert sendable["invoice_number"] == "INV-001"
    assert [warning] = packet.warnings
    assert packet.blocked == []
    assert Enum.any?(warning.issues, &(&1["code"] == "printed_taxable_mismatch"))
    refute Enum.any?(warning.issues, &(&1["code"] == "tally_export_failed"))
  end

  test "keeps missing HSN/SAC sendable as a named warning", ctx do
    invoice = put_in(ctx.invoice, ["line_items", Access.at(0), "hsn_sac"], nil)

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invoice])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert [sendable] = packet.invoices
    assert sendable["invoice_number"] == "INV-001"
    assert [held] = packet.warnings
    assert packet.blocked == []

    assert [%{"code" => "missing_hsn_sac", "lines" => [1]}] = held.issues
    refute Enum.any?(held.issues, &(&1["code"] == "tally_export_failed"))
  end

  test "does not apply month sequence controls to an arbitrary Tally batch", ctx do
    later =
      ctx.invoice
      |> Map.put("id", "source-3")
      |> Map.put("invoice_number", "INV-003")

    ctx.dump
    |> Ecto.Changeset.change(invoices: [ctx.invoice, later])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert Enum.map(packet.invoices, & &1["invoice_number"]) == ["INV-001", "INV-003"]
    assert packet.needs_review == []
  end

  test "evaluates rate history relative to each invoice month in a mixed-period batch", ctx do
    historical =
      ctx.invoice
      |> Map.put("id", "historical-source")
      |> Map.put("invoice_number", "OLD-001")
      |> Map.put("invoice_date", ~D[2026-05-01])
      |> put_in(["line_items", Access.at(0), "igst_rate"], 5)
      |> put_in(["line_items", Access.at(0), "igst_amount"], 50)

    Repo.insert!(%Month{
      org_id: ctx.org.id,
      client_id: ctx.client.id,
      period: "2026-05",
      invoices: [historical]
    })

    may =
      ctx.invoice
      |> Map.put("id", "may-source")
      |> Map.put("invoice_number", "MAY-001")
      |> Map.put("invoice_date", ~D[2026-05-15])

    june =
      ctx.invoice
      |> Map.put("id", "june-source")
      |> Map.put("invoice_number", "JUNE-001")
      |> Map.put("invoice_date", ~D[2026-06-15])

    ctx.dump
    |> Ecto.Changeset.change(invoices: [may, june])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert Enum.map(packet.invoices, & &1["invoice_number"]) == ["MAY-001", "JUNE-001"]
    assert [%{invoice: %{"invoice_number" => "JUNE-001"}, issues: issues}] = packet.warnings
    assert Enum.any?(issues, &(&1["code"] == "rate_history_conflict"))
  end

  test "Tally note readiness does not inherit the GSTR-1 original-sale question", ctx do
    note =
      ctx.invoice
      |> Map.put("document_type", "credit_note")
      |> Map.put("recipient_registration", "unregistered")
      |> Map.put("buyer_gstin", nil)
      |> Map.put("place_of_supply", "29")

    ctx.dump
    |> Ecto.Changeset.change(invoices: [note])
    |> Repo.update!()

    assert Enum.any?(Nila.Gst.Sales.Gstr1.blocking_issues([note]), fn issue ->
             issue["code"] == "missing_original_sale_category"
           end)

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert [ready] = packet.invoices
    assert ready["document_type"] == "credit_note"
    assert packet.needs_review == []
  end

  test "keeps exempt supply blocked while Tally XML hardcodes taxable treatment", ctx do
    invoice =
      update_in(ctx.invoice, ["line_items", Access.at(0)], fn line ->
        line
        |> Map.put("igst_rate", 0)
        |> Map.put("igst_amount", 0)
      end)
      |> Map.put("supply_type", "exempt")

    ctx.dump
    |> Ecto.Changeset.change(invoices: [invoice])
    |> Repo.update!()

    refute Enum.any?(Nila.Gst.Sales.Gstr1.blocking_issues([invoice]), fn issue ->
             issue["code"] == "exempt_supply_unsupported"
           end)

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert packet.invoices == []
    assert [held] = packet.blocked
    assert Enum.any?(held.issues, &(&1["code"] == "exempt_supply_unsupported"))
  end

  test "keeps unsupported Tally output treatments as target-specific blockers", ctx do
    export =
      ctx.invoice
      |> Map.put("supply_type", "export")
      |> Map.put("document", %{"export" => true})

    ctx.dump
    |> Ecto.Changeset.change(invoices: [export])
    |> Repo.update!()

    packet = TallyPacket.prepare([Repo.reload!(ctx.dump)])

    assert packet.invoices == []
    assert [held] = packet.blocked
    assert Enum.any?(held.issues, &(&1["code"] == "export_supply_unsupported"))
  end

  test "saves one complete invoice workbench submission atomically", ctx do
    company = company_fixture(ctx.org, "Nila")

    party =
      ledger_fixture(ctx.org.id, company.id, "party", "Customer AP", %{
        "parent" => "Sundry Debtors"
      })

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

    party =
      ledger_fixture(ctx.org.id, company.id, "party", "Customer AP", %{
        "parent" => "Sundry Debtors"
      })

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

  test "does not pin a Sales batch when its posting submission rolls back", ctx do
    company = company_fixture(ctx.org, "Nila")

    party =
      ledger_fixture(ctx.org.id, company.id, "party", "Customer AP", %{
        "parent" => "Sundry Debtors"
      })

    sales =
      ledger_fixture(ctx.org.id, company.id, "sales", "Material Sales", %{
        "parent" => "Sales Accounts"
      })

    invalid = ledger_fixture(ctx.org.id, company.id, "tax", "Output IGST", %{})
    {:ok, batch} = Batch.create(ctx.org.id, ctx.client.id, Ecto.UUID.generate())

    ctx.dump
    |> Ecto.Changeset.change(sales_batch_id: batch.id)
    |> Repo.update!()

    assert {:error, {:sales_ledger_not_found, 0}} =
             InvoiceCorrections.save_batch_workbench(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               batch.id,
               "source-1",
               company.id,
               %{
                 invoice: %{"invoice_number" => "MUST-ROLL-BACK"},
                 party_ledger_identity: party.identity,
                 posting_profile: %{sales_ledger_identity: sales.identity},
                 line_sales_ledger_identities: %{"0" => invalid.identity}
               },
               ctx.user.id
             )

    assert Repo.reload!(batch).tally_company_id == nil
    assert Repo.aggregate(InvoiceCorrection, :count) == 0
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

  test "a correction follows its source into a different batch", ctx do
    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{buyer_name: "Corrected once"}
             )

    second_invoice =
      ctx.invoice
      |> Map.put("id", "source-2")
      |> Map.put("invoice_number", "INV-002")

    {:ok, second_dump} =
      Dumps.record(
        %{org_id: ctx.org.id, client_id: ctx.client.id},
        %{
          period: "2026-07",
          kind: "sales",
          status: "extracted",
          invoices: [second_invoice]
        }
      )

    expanded_batch = [Repo.reload!(ctx.dump), second_dump]
    packet = TallyPacket.prepare(expanded_batch)

    corrected = Enum.find(packet.all_invoices, &(&1["id"] == "source-1"))
    assert corrected["buyer_name"] == "Corrected once"
    refute TallyPacket.ref(expanded_batch) == ctx.batch_ref
  end

  test "a source correction is replayed by the month projection", ctx do
    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ctx.batch_ref,
               "source-1",
               %{buyer_name: "Corrected customer"}
             )

    month =
      Repo.insert!(%Month{
        org_id: ctx.org.id,
        client_id: ctx.client.id,
        period: "2026-07",
        invoices: [ctx.invoice]
      })

    assert [effective] = Resolutions.workings(month).source_invoices
    assert effective["buyer_name"] == "Corrected customer"
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
