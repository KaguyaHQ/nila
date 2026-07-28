defmodule Nila.Gst.Extraction.WindowedTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Windowed
  alias Nila.PdfFixtures

  describe "plan/2" do
    test "windows a packet with a fixed stride and clamps the last window" do
      assert Windowed.plan(1) == [1..1]
      assert Windowed.plan(8) == [1..8]
      assert Windowed.plan(9) == [1..8, 7..9]
      assert Windowed.plan(14) == [1..8, 7..14]

      windows = Windowed.plan(57)

      assert List.first(windows) == 1..8
      assert List.last(windows) == 55..57
      assert length(windows) == 10
      assert Enum.all?(windows, &(Enum.count(&1) <= 8))
      assert Enum.map(windows, &Enum.min/1) == [1, 7, 13, 19, 25, 31, 37, 43, 49, 55]
    end

    test "covers every page, with every seam overlapped by two" do
      covered =
        57 |> Windowed.plan() |> Enum.flat_map(&Enum.to_list/1) |> Enum.uniq() |> Enum.sort()

      assert covered == Enum.to_list(1..57)

      Windowed.plan(57)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] ->
        shared = MapSet.intersection(MapSet.new(previous), MapSet.new(next))
        assert MapSet.size(shared) == Windowed.overlap()
      end)
    end

    test "an empty document plans nothing" do
      assert Windowed.plan(0) == []
      assert Windowed.plan(nil) == []
    end
  end

  describe "extract/3 — small packets" do
    test "a packet inside one window is a single whole-document call" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        send(test_pid, {:request, payload["pages"]})

        Req.Test.json(conn, response(1..5, [invoice("DPS-0072", [2])]))
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(5))

      assert_receive {:request, nil}
      refute_receive {:request, _pages}

      assert [artifact] = result.pages
      assert artifact["source_pages"] == [2]
      assert artifact["data"]["invoice_number"] == "DPS-0072"
    end

    test "an image is one call and one page" do
      Req.Test.stub(Mistral, fn conn ->
        assert payload(conn)["document"]["type"] == "image_url"
        Req.Test.json(conn, response(1..1, [invoice("DPS-0072", [1])]))
      end)

      assert {:ok, result} =
               Windowed.extract(:purchase, <<0xFF, 0xD8, 0xFF, 0x00>>, filename: "bill.jpg")

      assert [_artifact] = result.pages
      assert result.unaccounted_pages == []
    end
  end

  describe "extract/3 — windowing" do
    test "cuts a big packet into overlapping windows, 0-indexed at the wire" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        send(test_pid, {:request, payload["pages"]})

        conn |> respond(payload, [invoice("A-1", [3]), invoice("B-2", [10])])
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert_receive {:request, first_window}
      assert_receive {:request, second_window}

      assert Enum.sort([first_window, second_window]) == [
               [0, 1, 2, 3, 4, 5, 6, 7],
               [6, 7, 8, 9, 10, 11, 12, 13]
             ]

      assert Enum.map(result.pages, & &1["data"]["invoice_number"]) == ["A-1", "B-2"]
      assert Enum.map(result.pages, & &1["source_pages"]) == [[3], [10]]
      assert result.audit.windows == 2
      assert result.audit.source_page_count == 14
      assert result.audit.usage["pages_processed"] == 16
    end

    test "translates a window's relative page numbering back to document pages" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        respond(conn, payload, [invoice("A-1", [3]), invoice("B-2", [10])], indexing: :relative)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert Enum.map(result.pages, & &1["source_pages"]) == [[3], [10]]
      assert Enum.map(result.pages, & &1["page"]) == [3, 10]
    end
  end

  describe "extract/3 — overlap echoes" do
    test "collapses an echo, keeping the richer record and unioning its pages" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        # Page 7 is the shared seam: the first window sees the invoice cut at
        # its edge and reads less of it, the second sees it whole.
        invoices =
          if 0 in payload["pages"],
            do: [invoice("SEAM-1", [7], line_items: [], total: nil)],
            else: [invoice("SEAM-1", [7, 8])]

        respond(conn, payload, invoices)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert [artifact] = result.pages
      assert artifact["source_pages"] == [7, 8]
      assert artifact["page"] == 7
      assert artifact["data"]["printed_grand_total"] == 11_800
      assert artifact["data"]["line_items"] != []
    end

    test "keeps the same invoice number on pages that don't touch" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        invoices =
          if 0 in payload["pages"],
            do: [invoice("TWICE-1", [2])],
            else: [invoice("TWICE-1", [12])]

        respond(conn, payload, invoices)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert Enum.map(result.pages, & &1["source_pages"]) == [[2], [12]]
    end

    test "never collapses records with no invoice number" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        invoices =
          if 0 in payload["pages"],
            do: [invoice(nil, [7])],
            else: [invoice(nil, [7])]

        respond(conn, payload, invoices)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert length(result.pages) == 2
    end
  end

  describe "extract/3 — the ledger" do
    test "reports the pages no invoice claims" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        respond(conn, payload, [invoice("A-1", [3])])
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert [artifact] = result.pages
      assert artifact["source_pages"] == [3]
      assert result.unaccounted_pages == [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    end

    test "a window that drops an invoice leaves its page unaccounted" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        # The RAC2451 failure in miniature: page 10 is read, its invoice is
        # simply missing from the annotation, and the response is a clean 200.
        invoices = if 0 in payload["pages"], do: [invoice("A-1", [3])], else: []

        respond(conn, payload, invoices)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert Enum.map(result.pages, & &1["data"]["invoice_number"]) == ["A-1"]
      assert 10 in result.unaccounted_pages
    end
  end

  describe "extract/3 — failure and retry" do
    @tag :capture_log
    test "retries a window once, and the retry's result stands" do
      counter = :counters.new(1, [])

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        if 0 in payload["pages"] and :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)

          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "overloaded"})
        else
          respond(conn, payload, [invoice("A-1", [3]), invoice("B-2", [10])])
        end
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(14))

      assert :counters.get(counter, 1) == 1
      assert Enum.map(result.pages, & &1["data"]["invoice_number"]) == ["A-1", "B-2"]
    end

    @tag :capture_log
    test "a window that keeps failing fails the packet, naming its pages" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        if 0 in payload["pages"] do
          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "overloaded"})
        else
          respond(conn, payload, [invoice("B-2", [10])])
        end
      end)

      assert {:error, {:extraction_window_failed, "1-8", reason}} = extract(PdfFixtures.pdf(14))
      assert {:mistral_ocr_failed, 503, _body} = reason
    end

    test "a whole-document call that extracts nothing is still a failure" do
      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..5, []))
      end)

      assert {:error, {:extraction_window_failed, "all", :no_invoices_extracted}} =
               extract(PdfFixtures.pdf(5))
    end
  end

  describe "extract/3 — :per_call" do
    test "wraps every provider call with the window's page range" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        respond(conn, payload, [invoice("A-1", [3]), invoice("B-2", [10])])
      end)

      per_call = fn metadata, call ->
        send(test_pid, {:per_call, metadata})
        call.()
      end

      assert {:ok, _result} = extract(PdfFixtures.pdf(14), per_call: per_call)

      assert_receive {:per_call, %{"pages" => first}}
      assert_receive {:per_call, %{"pages" => second}}
      assert Enum.sort([first, second]) == ["1-8", "7-14"]
    end
  end

  describe "extract/3 — :on_window" do
    test "reports the plan first, then pages covered as each window lands" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        respond(conn, payload, [invoice("A-1", [3])])
      end)

      on_window = fn event -> send(test_pid, event) end

      assert {:ok, _result} = extract(PdfFixtures.pdf(20), on_window: on_window)

      # The plan lands before any provider call, so a screen can show the size
      # of the job rather than a spinner over an unknown wait.
      assert_receive {:progress, %{done: 0, total: 3, pages_done: 0, page_count: 20}}

      # Overlapping windows are unioned, so pages_done never double-counts and
      # ends at the real page count.
      assert_receive {:progress, %{done: 1, pages_done: 8, page_count: 20}}
      assert_receive {:progress, %{done: 2, pages_done: 14, page_count: 20}}
      assert_receive {:progress, %{done: 3, pages_done: 20, page_count: 20}}
      refute_receive {:progress, _more}
    end

    test "a single whole-document call still reports a plan and a finish" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..5, [invoice("DPS-0072", [2])]))
      end)

      on_window = fn event -> send(test_pid, event) end

      assert {:ok, _result} = extract(PdfFixtures.pdf(5), on_window: on_window)

      assert_receive {:progress, %{done: 0, total: 1, pages_done: 0, page_count: 5}}
      assert_receive {:progress, %{done: 1, total: 1, pages_done: 5, page_count: 5}}
    end

    test "an image is one page" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..1, [invoice("IMG-1", [1])]))
      end)

      on_window = fn event -> send(test_pid, event) end

      assert {:ok, _result} =
               Windowed.extract(:purchase, "not-a-pdf",
                 filename: "bill.png",
                 on_window: on_window
               )

      assert_receive {:progress, %{done: 1, total: 1, page_count: 1}}
    end

    # `pdfinfo` failing on a PDF is the one case with no page count to report.
    # `page_count: nil` is the signal for that, and it is what makes a screen
    # fall back to window counts rather than render a bar against a made-up total.
    @tag :capture_log
    test "a page count pdfinfo cannot read reports nil rather than inventing one" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..1, [invoice("A-1", [1])]))
      end)

      on_window = fn event -> send(test_pid, event) end

      assert {:ok, _result} = extract("%PDF-1.4 truncated", on_window: on_window)

      assert_receive {:progress, %{done: 0, total: 1, page_count: nil}}
      assert_receive {:progress, %{done: 1, total: 1, page_count: nil}}
    end

    test "extraction runs unchanged when no callback is given" do
      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)
        respond(conn, payload, [invoice("A-1", [3])])
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(20))
      assert result.unaccounted_pages != nil
    end

    # A resent window holds the bar still for another provider round-trip. The
    # live failure this was written from (`Req.TransportError{reason: :closed}`
    # on a 15-page packet) sat silent for ~40s per retry.
    @tag :capture_log
    test "a resent window is reported rather than sat through in silence" do
      test_pid = self()
      counter = :counters.new(1, [])

      Req.Test.stub(Mistral, fn conn ->
        payload = payload(conn)

        if 0 in payload["pages"] and :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          Req.Test.transport_error(conn, :closed)
        else
          respond(conn, payload, [invoice("A-1", [3])])
        end
      end)

      on_window = fn event -> send(test_pid, event) end

      assert {:ok, _result} = extract(PdfFixtures.pdf(14), on_window: on_window)

      assert_receive {:retrying, "1-8"}
      assert_receive {:progress, %{done: 2, total: 2, pages_done: 14}}
    end
  end

  describe "extract/3 — evidence" do
    test "renders every page and points each artifact at the one it was read from" do
      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..5, [invoice("A-1", [3])]))
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(5))

      assert result.images |> Map.keys() |> Enum.sort() ==
               ~w(page_01.png page_02.png page_03.png page_04.png page_05.png)

      assert Enum.all?(Map.values(result.images), &(byte_size(&1) > 0))

      assert [artifact] = result.pages
      assert artifact["image"] == "page_03.png"
      refute Map.has_key?(result, :evidence_error)
    end

    # Pointing an unplaceable invoice at a page anyway would put the wrong bill
    # in front of a reviewer, which is worse than putting none there: they would
    # check an invoice against a picture of a different one and see no problem.
    test "an invoice extraction could not place points at no page" do
      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..5, [invoice("A-1", [])]))
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(5))

      assert [artifact] = result.pages
      assert artifact["source_pages"] == []
      assert artifact["image"] == nil
    end

    # A packet the provider reads but poppler cannot render still has to produce
    # a register: the pictures are how a reviewer checks, not what they check.
    @tag :capture_log
    test "a document that will not render still extracts, and says so" do
      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..1, [invoice("A-1", [1])]))
      end)

      assert {:ok, result} = extract("%PDF-1.4 truncated")

      assert [artifact] = result.pages
      assert artifact["data"]["invoice_number"] == "A-1"
      assert artifact["image"] == nil
      assert result.images == %{}
      assert {:page_render_failed, 1, _output} = result.evidence_error
    end

    # An image packet is already its own evidence — nothing to rasterize, and
    # nothing broken, so it must not read as a gap.
    test "an image packet renders nothing and reports no gap" do
      Req.Test.stub(Mistral, fn conn ->
        Req.Test.json(conn, response(1..1, [invoice("IMG-1", [1])]))
      end)

      assert {:ok, result} =
               Windowed.extract(:purchase, <<0xFF, 0xD8, 0xFF, 0x00>>, filename: "bill.jpg")

      assert result.images == %{}
      refute Map.has_key?(result, :evidence_error)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp extract(bytes, opts \\ []) do
    Windowed.extract(:purchase, bytes, Keyword.merge([filename: "bills.pdf"], opts))
  end

  defp payload(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  # The window as the provider was asked for it (0-indexed) turned back into
  # document pages, then a response numbered the way the test wants.
  defp respond(conn, payload, invoices, opts \\ []) do
    page_numbers =
      case payload["pages"] do
        nil -> [1]
        pages -> Enum.map(pages, &(&1 + 1))
      end

    window = MapSet.new(page_numbers)
    visible = Enum.filter(invoices, &Enum.all?(&1.pages, fn page -> page in window end))

    Req.Test.json(conn, response(page_numbers, visible, opts))
  end

  defp invoice(number, pages, opts \\ []) do
    %{
      number: number,
      pages: pages,
      gstin: Keyword.get(opts, :gstin, "32AAMFD7558A1ZL"),
      total: Keyword.get(opts, :total, 11_800),
      line_items:
        Keyword.get(opts, :line_items, [
          %{
            "description" => "Battery",
            "hsn_sac" => "8507",
            "quantity" => 1,
            "taxable_value" => 10_000,
            "igst_rate" => 18,
            "igst_amount" => 1_800
          }
        ])
    }
  end

  defp response(page_numbers, invoices, opts \\ []) do
    page_numbers = Enum.to_list(page_numbers)
    indexing = Keyword.get(opts, :indexing, :absolute)

    pages =
      page_numbers
      |> Enum.with_index()
      |> Enum.map(fn {page, position} ->
        %{
          "index" => if(indexing == :absolute, do: page - 1, else: position),
          "markdown" => page_markdown(page, invoices),
          "blocks" => [],
          "confidence_scores" => %{
            "minimum_page_confidence_score" => 0.95,
            "average_page_confidence_score" => 0.99
          }
        }
      end)

    %{
      "model" => "mistral-ocr-4-0",
      "pages" => pages,
      "document_annotation" => %{
        "invoices" => Enum.map(invoices, &annotation(&1, page_numbers, indexing))
      },
      "usage_info" => %{"pages_processed" => length(page_numbers)}
    }
  end

  defp page_markdown(page, invoices) do
    invoices
    |> Enum.filter(&(page in &1.pages))
    |> Enum.map_join("\n", fn invoice ->
      "Invoice #{invoice.number} GSTIN #{invoice.gstin} total #{invoice.total}"
    end)
    |> case do
      "" -> "page #{page}"
      text -> text
    end
  end

  defp annotation(invoice, page_numbers, indexing) do
    source_pages =
      Enum.map(invoice.pages, fn page ->
        case indexing do
          :absolute -> page
          :relative -> Enum.find_index(page_numbers, &(&1 == page)) + 1
        end
      end)

    %{
      "source_pages" => source_pages,
      "invoice_number" => invoice.number,
      "invoice_date" => "08-10-2025",
      "seller" => %{"name" => "Dawn Power", "gstin" => invoice.gstin},
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "line_items" => invoice.line_items,
      "printed_grand_total" => invoice.total
    }
  end
end
