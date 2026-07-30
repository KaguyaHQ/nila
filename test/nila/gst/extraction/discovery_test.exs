defmodule Nila.Gst.Extraction.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Discovery
  alias Nila.Gst.Extraction.Discovery.Features
  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Transcription

  defp transcription(pages) do
    body =
      Jason.encode!(%{
        "pages" =>
          Enum.map(pages, fn {number, markdown} ->
            %{"index" => number - 1, "markdown" => markdown}
          end)
      })

    {:ok, transcription} = Transcription.from_response(body)
    transcription
  end

  defp decider_response(segments) do
    %{
      status: 200,
      headers: %{},
      body:
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => Jason.encode!(%{"segments" => segments})}}]
        })
    }
  end

  defp segment(pages, opts \\ []) do
    %{
      "pages" => pages,
      "kind" => Keyword.get(opts, :kind, "invoice"),
      "invoice_no" => Keyword.get(opts, :invoice_no),
      "reason" => nil
    }
  end

  describe "guards" do
    test "a page the decider forgot comes back as a violation, never as silence" do
      t = transcription([{1, "INV-1"}, {2, "INV-2"}, {3, "INV-3"}])

      {:ok, %{segments: segments, violations: violations}} =
        Discovery.map_response(t, decider_response([segment([1]), segment([2])]))

      assert {:pages_unaccounted, [3]} in violations
      assert Enum.find(segments, &(&1.pages == [3])).kind == :unreadable
      # Conservation still holds afterwards: the ledger covers every page.
      assert segments |> Enum.flat_map(& &1.pages) |> Enum.sort() == [1, 2, 3]
    end

    test "a page claimed twice goes to the first claimant and the second says so" do
      t = transcription([{1, "INV-1"}, {2, "INV-2"}])

      {:ok, %{segments: segments, violations: violations}} =
        Discovery.map_response(t, decider_response([segment([1, 2]), segment([2])]))

      assert Enum.map(segments, & &1.pages) == [[1, 2]]
      assert {:pages_double_claimed, [2]} in violations
    end

    test "a non-contiguous segment is a violation — scanned packets do not interleave" do
      t = transcription([{1, "INV-1"}, {2, "other"}, {3, "INV-1 continued"}])

      {:ok, %{violations: violations}} =
        Discovery.map_response(t, decider_response([segment([1, 3]), segment([2])]))

      assert {:segments_not_contiguous, [[1, 3]]} in violations
    end

    test "an invoice number that is not on its own pages is not grounded" do
      t = transcription([{1, "TAX INVOICE No. BRZ/26/020"}, {2, "TAX INVOICE No. BRZ/26/021"}])

      {:ok, %{segments: segments, violations: violations}} =
        Discovery.map_response(
          t,
          decider_response([
            segment([1], invoice_no: "BRZ/26/020"),
            segment([2], invoice_no: "BRZ-26-099")
          ])
        )

      assert [first, second] = segments
      assert first.grounded? == true
      assert second.grounded? == false
      assert {:invoice_numbers_not_grounded, ["BRZ-26-099"]} in violations
    end

    test "grounding ignores punctuation, so BRZ/26/020 matches BRZ-26-020 on the page" do
      t = transcription([{1, "TAX INVOICE No. BRZ-26-020"}])

      {:ok, %{segments: [segment]}} =
        Discovery.map_response(t, decider_response([segment([1], invoice_no: "BRZ/26/020")]))

      assert segment.grounded? == true
    end

    test "a non-invoice verdict nothing on the page confirms is left unaccounted" do
      # "Not an invoice" is the one verdict that ends a page's life — never
      # extracted, never flagged, counted as accounted for. So it needs proof:
      # a printed marker of what the page actually is. Without one the page
      # becomes unreadable and the ledger reports it, rather than a possible
      # purchase leaving the return in silence.
      t = transcription([{1, "INV-1"}, {2, "nondescript page"}])

      {:ok, %{segments: segments, violations: violations}} =
        Discovery.map_response(
          t,
          decider_response([segment([1]), segment([2], kind: "non_invoice")])
        )

      assert Enum.map(segments, & &1.kind) == [:invoice, :unreadable]
      assert {:unconfirmed_non_invoice_pages, [[2]]} in violations
    end

    test "on a sales packet a bill with no customer GSTIN is still rescued" do
      # The rescue used to be "a valid GSTIN that is not the client's", which on
      # a purchase packet is the supplier and on a sales packet is the customer
      # — absent on every B2C bill. A page carrying an e-way bill number matches
      # the non-invoice marker, so without a working rescue the sale would be
      # counted as accounted for and vanish from the return with no flag.
      t =
        transcription([
          {1, "TAX INVOICE 5\nGSTIN 33AAKCS8613A1ZM\nCGST 9 SGST 9\nGrand total 118.00"},
          {2, "TAX INVOICE 6\nE-Way Bill No. 3312\nCGST 18 SGST 18\nGrand total 236.00"}
        ])

      labels = [
        %{page: 1, label: :start, invoice_no: "5", reason: nil},
        %{page: 2, label: :non_invoice, invoice_no: nil, reason: nil}
      ]

      segments = PageLabels.stitch(labels)

      {sales, _violations} = Discovery.guard(t, segments, kind: :sales)
      assert Enum.map(sales, & &1.kind) == [:invoice, :invoice]

      # The same page in a purchase pile has a supplier GSTIN to prove it, which
      # is why the corpus never caught this.
      {purchase, _violations} = Discovery.guard(t, segments, kind: :purchase)
      assert Enum.map(purchase, & &1.kind) == [:invoice, :non_invoice]
    end

    test "on a sales packet two customer GSTINs do not split one bill" do
      # Bill-to and ship-to are the same document. On a purchase packet two
      # valid non-client GSTINs are two suppliers and therefore two bills; on a
      # sales packet they are two addresses on one.
      t =
        transcription([
          {1, "TAX INVOICE 7\nBill to GSTIN 33AAKCS8613A1ZM\nTaxable 100"},
          {2, "Ship to GSTIN 32AAMFD7558A1ZL\nTotal 118.00"}
        ])

      segment = [%{pages: [1, 2], kind: :invoice, invoice_no: "7", reason: nil, issues: []}]

      {[sales], _violations} = Discovery.guard(t, segment, kind: :sales)
      assert sales.pages == [1, 2]

      {purchase, _violations} = Discovery.guard(t, segment, kind: :purchase)
      assert Enum.map(purchase, & &1.pages) == [[1], [2]]
    end

    test "a clean segmentation raises no violations" do
      t = transcription([{1, "INV-1"}, {2, "INV-1 continued"}, {3, "DELIVERY CHALLAN no. 42"}])

      {:ok, %{segments: segments, violations: []}} =
        Discovery.map_response(
          t,
          decider_response([segment([1, 2]), segment([3], kind: "non_invoice")])
        )

      assert Enum.map(segments, & &1.kind) == [:invoice, :non_invoice]
    end
  end

  describe "features" do
    test "reads a Tally label grid's invoice number out of the cell below the label" do
      markdown = """
      | Invoice No. | Dated |
      | :-- | :-- |
      | BRZ/26/020 | 8-Jun-26 |
      """

      assert Features.invoice_number(markdown) == "BRZ/26/020"
    end

    test "rejects the junk a same-line regex would have captured" do
      # The naive read of this layout returns "Dated" and then a whole date string.
      markdown = "Invoice No. Dated 8-Jun-26 Mode/Terms of Payment 30 Days"

      assert Features.invoice_number(markdown) == nil
    end

    test "validates GSTIN check digits rather than only their shape" do
      features = Features.scan("GSTIN 33AAKCS8613A1ZM and 33AAKCS8613A1ZQ")

      assert length(features.gstins) == 2
      assert features.gstins_valid == ["33AAKCS8613A1ZM"]
    end

    test "counts table rows, which is what the per-call row budget is spent on" do
      markdown = "| a | b |\n| 1 | 2 |\n| 3 | 4 |\nnot a row"

      assert Features.scan(markdown).table_rows == 3
    end
  end
end
