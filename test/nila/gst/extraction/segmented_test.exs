defmodule Nila.Gst.Extraction.SegmentedTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.Gst.Extraction.Segmented
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

  defp segment(pages, invoice_no \\ nil) do
    %{pages: pages, kind: :invoice, invoice_no: invoice_no, reason: nil, issues: []}
  end

  defp reply(conn, invoice) do
    Req.Test.json(conn, %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(invoice)}}],
      "usage" => %{"total_tokens" => 100}
    })
  end

  defp invoice_page(number) do
    """
    TAX INVOICE No. BRZ/26/0#{number}
    | Item | Qty | Amount |
    | Bolt | 4 | 1,000.00 |
    Taxable 1,000.00  CGST 90.00  SGST 90.00
    Total tax 180.00
    Grand total 1,180.00
    """
  end

  test "one call carries exactly one invoice, and its pages are a fact not a guess" do
    t = transcription([{5, invoice_page(5)}, {6, "continued\nGrand total 1,180.00"}])

    Req.Test.expect(MistralChat, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["response_format"]["json_schema"]["strict"] == true
      # The schema is one invoice, not an array of them: there is no budget to
      # split and nothing to truncate.
      properties = payload["response_format"]["json_schema"]["schema"]["properties"]
      assert Map.has_key?(properties, "printed_grand_total")
      refute Map.has_key?(properties, "invoices")
      refute Map.has_key?(properties, "source_pages")

      [_system, user] = payload["messages"]
      assert user["content"] =~ "--- page 5 ---"
      assert user["content"] =~ "--- page 6 ---"

      reply(conn, %{
        "invoice_number" => "BRZ/26/05",
        "seller" => %{"gstin" => nil, "name" => "Breeze"},
        "line_items" => [%{"taxable_value" => 1_000.0, "cgst_rate" => 9.0, "sgst_rate" => 9.0}],
        "printed_total_taxable" => 1_000.0,
        "printed_cgst" => 90.0,
        "printed_sgst" => 90.0,
        "printed_total_tax" => 180.0,
        "printed_grand_total" => 1_180.0
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([5, 6], "BRZ/26/05"))

    assert artifact["source_pages"] == [5, 6]
    assert artifact["page"] == 5
    assert artifact["source_attribution"]["status"] == "verified"
    assert artifact["data"]["is_invoice"] == true
    assert artifact["verification"]["status"] == "verified"
  end

  test "a fabricated total is caught before the artifact leaves the stage" do
    t = transcription([{1, invoice_page(1)}])

    Req.Test.expect(MistralChat, fn conn ->
      reply(conn, %{
        "invoice_number" => "BRZ/26/01",
        "line_items" => [%{"taxable_value" => 1_000.0}],
        # 9,999 appears nowhere on the page.
        "printed_total_taxable" => 9_999.0,
        "printed_grand_total" => 1_180.0
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([1]))

    assert artifact["verification"]["status"] == "flagged"
    assert [%{"flag" => "value_not_on_page"} | _rest] = artifact["verification"]["flags"]
  end

  test "a segment too dense for one output budget is split before the call, not after" do
    rows = Enum.map_join(1..100, "\n", fn n -> "| Item #{n} | 1 | 10.00 |" end)
    t = transcription([{1, "TAX INVOICE\n" <> rows}, {2, rows <> "\nGrand total 2,000.00"}])

    # 200 rows over two pages exceeds the per-call row limit, so the invoice is
    # read in two calls and merged in code — the escape hatch that only exists
    # because the input is text and therefore measurable in advance.
    assert Segmented.row_limit() < 200

    Req.Test.expect(MistralChat, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [_system, user] = Jason.decode!(body)["messages"]

      if user["content"] =~ "--- page 1 ---" do
        reply(conn, %{
          "invoice_number" => "BIG-1",
          "line_items" => Enum.map(1..100, fn _n -> %{"taxable_value" => 10.0} end),
          "printed_total_taxable" => nil
        })
      else
        assert user["content"] =~ "CONTINUATION"

        reply(conn, %{
          "invoice_number" => nil,
          "line_items" => Enum.map(1..100, fn _n -> %{"taxable_value" => 10.0} end),
          "printed_total_taxable" => 2_000.0
        })
      end
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([1, 2], "BIG-1"))

    assert length(artifact["data"]["line_items"]) == 200
    assert artifact["data"]["invoice_number"] == "BIG-1"
    assert artifact["data"]["printed_total_taxable"] == 2_000.0
  end

  test "the ledger reports a page no invoice claimed, and accounts for challans" do
    t = transcription([{1, invoice_page(1)}, {2, "DELIVERY CHALLAN"}, {3, "???"}])

    Req.Test.expect(MistralChat, fn conn ->
      reply(conn, %{
        "invoice_number" => "BRZ/26/01",
        "line_items" => [%{"taxable_value" => 1_000.0}],
        "printed_total_taxable" => 1_000.0,
        "printed_grand_total" => 1_180.0
      })
    end)

    segments = [
      segment([1]),
      %{pages: [2], kind: :non_invoice, invoice_no: nil, reason: nil, issues: []},
      %{pages: [3], kind: :unreadable, invoice_no: nil, reason: nil, issues: []}
    ]

    result = Segmented.extract(:purchase, t, segments)

    assert length(result.pages) == 1
    assert result.unaccounted_pages == [3]
  end
end
