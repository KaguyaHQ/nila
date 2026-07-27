defmodule Nila.Gst.Intake.EvidenceBackfillTest do
  use Nila.DataCase, async: false

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.{Dumps, EvidenceBackfill}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.PdfFixtures
  alias Nila.Storage

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{org: org, client: client, user: user}
  end

  describe "pending/1" do
    test "finds extracted dumps whose invoices name no page", ctx do
      blind = extracted_dump(ctx, [invoice("A-1", [1])])

      _sighted =
        extracted_dump(ctx, [invoice("B-1", [1]) |> Map.put("images", ["d9_page_01.png"])])

      assert [found] = EvidenceBackfill.pending()
      assert found.id == blind.id
    end

    # Sales invoices carry their basename in a scalar, purchase in a list.
    # Reading only one shape would re-render months that already have pictures.
    test "a sales dump naming its page in \"image\" is not pending", ctx do
      extracted_dump(ctx, [%{"invoice_number" => "S-1", "image" => "d9_page_01.png"}], "sales")

      assert EvidenceBackfill.pending() == []
    end

    test "scopes to one dump", ctx do
      _other = extracted_dump(ctx, [invoice("A-1", [1])])
      wanted = extracted_dump(ctx, [invoice("B-1", [1])])

      assert [found] = EvidenceBackfill.pending(dump_id: wanted.id)
      assert found.id == wanted.id
    end
  end

  describe "run/1" do
    test "renders the stored original and points each invoice at its page", ctx do
      dump = extracted_dump(ctx, [invoice("A-1", [1]), invoice("A-2", [2, 3])])

      assert {:ok, %{pages: 3, invoices: 2}} = EvidenceBackfill.run(dump)

      {:ok, reloaded} = Dumps.fetch(ctx.org.id, dump.id)
      assert [first, second] = reloaded.invoices
      assert first["images"] == ["d#{dump.id}_page_01.png"]
      assert second["images"] == ["d#{dump.id}_page_02.png", "d#{dump.id}_page_03.png"]

      # Stored where the evidence controller will look for it, with real bytes.
      assert {:ok, bytes} =
               PurchaseMonths.fetch_evidence(
                 ctx.org.id,
                 ctx.client.id,
                 "2025-10",
                 hd(first["images"])
               )

      assert byte_size(bytes) > 0
    end

    test "re-derives the month so the register rows carry the images", ctx do
      dump = extracted_dump(ctx, [invoice("A-1", [1])])

      assert {:ok, _report} = EvidenceBackfill.run(dump)

      {:ok, month} = PurchaseMonths.get_by_period(ctx.org.id, ctx.client.id, "2025-10")
      assert [row] = month.register_rows
      assert row["images"] == ["d#{dump.id}_page_01.png"]
    end

    # An invoice extraction could not place has no page to point at. Guessing one
    # renders the wrong bill beside a line, which is worse than rendering none.
    test "an invoice with no page number points at nothing", ctx do
      dump = extracted_dump(ctx, [Map.delete(invoice("A-1", [1]), "pages")])

      assert {:ok, %{invoices: 0}} = EvidenceBackfill.run(dump)

      {:ok, reloaded} = Dumps.fetch(ctx.org.id, dump.id)
      assert [invoice] = reloaded.invoices
      assert invoice["images"] == []
    end

    # A page number past the end of the packet would otherwise mint a URL for a
    # file nobody stored.
    test "a page number that did not render is not named", ctx do
      dump = extracted_dump(ctx, [invoice("A-1", [1, 99])])

      assert {:ok, _report} = EvidenceBackfill.run(dump)

      {:ok, reloaded} = Dumps.fetch(ctx.org.id, dump.id)
      assert [invoice] = reloaded.invoices
      assert invoice["images"] == ["d#{dump.id}_page_01.png"]
    end

    test "a dump whose original is gone reports rather than raises", ctx do
      dump = extracted_dump(ctx, [invoice("A-1", [1])])
      Storage.delete(hd(dump.file_keys))

      assert {:error, _reason} = EvidenceBackfill.run(dump)
    end
  end

  defp extracted_dump(ctx, invoices, kind \\ "purchase") do
    key = "orgs/#{ctx.org.id}/gst/#{System.unique_integer([:positive])}/original.pdf"
    {:ok, _stored} = Storage.put(key, PdfFixtures.pdf(3))

    {:ok, dump} =
      Dumps.record(
        %{org_id: ctx.org.id, client_id: ctx.client.id, brought_in_by_id: ctx.user.id},
        %{period: "2025-10", kind: kind, file_keys: [key]}
      )

    Dumps.mark_extracted(dump, invoices)
  end

  defp invoice(number, pages) do
    %{
      "id" => "inv_#{number}",
      "invoice_number" => number,
      "invoice_date" => "2025-10-08",
      "pages" => pages,
      "images" => [],
      "vendor_name" => "Dawn Power",
      "vendor_gstin" => "32AAMFD7558A1ZL",
      "taxable_paise" => 17_000,
      "tax_paise" => %{"igst" => 3060},
      "total_paise" => 20_060,
      "line_items" => []
    }
  end
end
