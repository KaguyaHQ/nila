defmodule Nila.Gst.Sales.SourcePacketTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps

  alias Nila.Gst.Sales.{Batch, SourcePacket}
  alias Nila.Gst.Sales.Gstr1.Packet, as: Gstr1Packet
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Gst.Sales.Invoice.Removals, as: InvoiceRemovals
  alias Nila.Gst.Sales.Tally.Packet, as: TallyPacket

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{org: org, client: client, user: user}
  end

  test "GSTR-1 can use valid invoice facts when a Tally voucher cannot be built", ctx do
    invoice = Map.put(invoice_fixture(), "buyer_name", nil)
    dump = record_dump(ctx, [invoice])

    assert [%{issues: issues}] = TallyPacket.prepare([dump]).blocked
    assert Enum.any?(issues, &(&1["code"] == "tally_export_failed"))

    assert {:ok, %{period: "2026-07", return: result}} =
             Gstr1Packet.build([dump], ctx.client.gstin)

    assert [%{"inv" => [%{"inum" => "INV-001"}]}] = result["b2b"]
  end

  test "source corrections and removals are shared across an expanded batch", ctx do
    dump = record_dump(ctx, [invoice_fixture()])
    ref = Batch.ref([dump])

    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ref,
               "source-1",
               %{"invoice_number" => "CORRECTED-1"},
               ctx.user.id
             )

    second =
      record_dump(ctx, [
        invoice_fixture() |> Map.put("id", "source-2") |> Map.put("invoice_number", "INV-002")
      ])

    assert {:ok, _} =
             InvoiceRemovals.remove(
               ctx.org.id,
               ctx.client.id,
               Batch.ref([second]),
               "source-2",
               ctx.user.id
             )

    source = SourcePacket.prepare([dump, second])
    assert [%{"invoice_number" => "CORRECTED-1"}] = source.invoices
    assert [%{"id" => "source-2"}] = source.excluded
    assert length(source.all_invoices) == 2
    assert TallyPacket.prepare([dump, second]).invoices == source.invoices
    assert {:ok, %{return: result}} = Gstr1Packet.build([dump, second], ctx.client.gstin)
    assert [%{"inv" => [%{"inum" => "CORRECTED-1"}]}] = result["b2b"]
  end

  test "partial invoices are opt-in for processing batch views", ctx do
    dump = record_dump(ctx, [invoice_fixture()], %{status: "extracting"})

    assert SourcePacket.prepare([dump]).all_invoices == []

    assert [%{"invoice_number" => "INV-001"}] =
             SourcePacket.prepare([dump], include_processing: true).all_invoices

    assert TallyPacket.prepare([dump]).all_invoices == []

    assert [%{"invoice_number" => "INV-001"}] =
             TallyPacket.prepare([dump], include_processing: true).all_invoices
  end

  test "source corrections and removals stay within their organization and client", ctx do
    dump = record_dump(ctx, [invoice_fixture()])
    ref = Batch.ref([dump])

    assert {:ok, _} =
             InvoiceCorrections.save(
               ctx.org.id,
               ctx.client.id,
               ref,
               "source-1",
               %{"invoice_number" => "PRIVATE-1"},
               ctx.user.id
             )

    assert {:ok, _} =
             InvoiceRemovals.remove(ctx.org.id, ctx.client.id, ref, "source-1", ctx.user.id)

    %{org: other_org} = user_with_org_fixture()

    for org <- [ctx.org, other_org] do
      {:ok, client} =
        Clients.create_client(%{
          org_id: org.id,
          name: "Other client",
          type: "company",
          gstin: "33BPBPK1081A1ZO"
        })

      other_dump = record_dump(%{org: org, client: client}, [invoice_fixture()])
      packet = SourcePacket.prepare([other_dump])
      assert [%{"invoice_number" => "INV-001"}] = packet.invoices
      assert packet.excluded == []
    end
  end

  test "source preparation retains failed files and unread pages", ctx do
    dump =
      record_dump(ctx, [invoice_fixture()], %{
        meta: %{"original_name" => "sales.pdf", "unaccounted_pages" => [3]}
      })

    failed = record_dump(ctx, [], %{status: "failed"})
    packet = SourcePacket.prepare([dump, failed])
    assert packet.failed_files == [failed]
    assert packet.unread_pages == [%{file: "sales.pdf", page: 3}]
  end

  defp record_dump(ctx, invoices, attrs \\ %{}) do
    {:ok, dump} =
      Dumps.record(
        %{org_id: ctx.org.id, client_id: ctx.client.id},
        Map.merge(
          %{period: "2026-07", kind: "sales", status: "extracted", invoices: invoices},
          attrs
        )
      )

    dump
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
