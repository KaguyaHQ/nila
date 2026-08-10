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

  test "a sales debit-note heading and structured type leave as the same classification" do
    text = """
    DEBIT NOTE # CDN-000001
    Date 10/08/2026
    Seller GSTIN 33AEWPH4158J1Z3
    Buyer GSTIN 29AAVCS8021P1ZB
    HSN 998719 Taxable 10,000.00 IGST 18% 1,800.00 Total 11,800.00
    """

    t = transcription([{1, text}])

    Req.Test.expect(MistralChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      schema = Jason.decode!(body)["response_format"]["json_schema"]["schema"]
      properties = schema["properties"]

      assert properties["recipient_registration"]["enum"] ==
               ["registered", "unregistered", "unknown"]

      assert Map.has_key?(properties, "place_of_supply")
      assert Map.has_key?(properties, "document_status")
      assert Map.has_key?(properties, "supply_type")
      line_properties = get_in(properties, ["line_items", "items", "properties"])
      assert Map.has_key?(line_properties, "item_name")
      assert Map.has_key?(line_properties, "tax_inclusive_value")
      assert Map.has_key?(line_properties, "tax_inclusive")
      assert line_properties["taxable_value"]["description"] =~ "Tax Inclusive"

      reply(conn, %{
        "document_type" => "debit_note",
        "recipient_registration" => "registered",
        "place_of_supply" => "Karnataka",
        "document_status" => "active",
        "supply_type" => "taxable",
        "invoice_number" => "CDN-000001",
        "invoice_date" => "10/08/2026",
        "seller" => %{"name" => "Seller", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "Buyer", "gstin" => "29AAVCS8021P1ZB"},
        "line_items" => [
          %{
            "hsn_sac" => "998719",
            "taxable_value" => 10_000,
            "igst_rate" => 18,
            "igst_amount" => 1_800
          }
        ],
        "printed_total_taxable" => 10_000,
        "printed_total_tax" => 1_800,
        "printed_grand_total" => 11_800
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:sales, t, segment([1], "CDN-000001"))

    assert artifact["data"]["document_type"] == "debit_note"
    assert artifact["document"]["debit_note"]
    refute artifact["document"]["credit_note"]
    assert artifact["document"]["extracted_type"] == "debit_note"
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

  describe "repairing a scan-damaged GSTIN against the known client" do
    # The scanner read the state code 33 as 03. The grammar cannot object — a
    # digit is legal there — so only the check digit fails, and only the
    # client's own number can settle it. The client sits on a different side of
    # the bill in each pile: buyer on what they bought, seller on what they
    # sold. Snapping the other side would rewrite a counterparty's identity, and
    # on a sales pile that counterparty changes every bill.
    @damaged "03AEWPH4158J1Z3"
    @client "33AEWPH4158J1Z3"

    test "on a purchase pile the client's own side is the buyer" do
      data = %{"seller" => %{"gstin" => @damaged}, "buyer" => %{"gstin" => @damaged}}

      {repaired, repairs} = Segmented.repair_gstins(data, :purchase, @client)

      assert repaired["buyer"]["gstin"] == @client
      assert repaired["seller"]["gstin"] == @damaged
      assert [%{"field" => "buyer.gstin", "basis" => "known_client"}] = repairs
    end

    test "on a sales pile it is the seller" do
      data = %{"seller" => %{"gstin" => @damaged}, "buyer" => %{"gstin" => @damaged}}

      {repaired, repairs} = Segmented.repair_gstins(data, :sales, @client)

      assert repaired["seller"]["gstin"] == @client
      assert repaired["buyer"]["gstin"] == @damaged
      assert [%{"field" => "seller.gstin", "basis" => "known_client"}] = repairs
    end
  end

  # A rate-limited segment sits in backoff for half a minute. Ordered delivery
  # would hold every later segment's report behind it, so the bar reads zero
  # while the rest of the pile is already read — which is what the operator
  # saw, and what sent them looking for a hung screen.
  test "a segment stuck in backoff does not hold back the count for the rest" do
    test_pid = self()
    t = transcription(Enum.map(1..3, &{&1, invoice_page(&1)}))

    Req.Test.stub(MistralChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(body)["messages"] |> List.last() |> Map.fetch!("content")

      if content =~ "--- page 1 ---" do
        send(test_pid, {:stuck, self()})
        receive do: (:release -> :ok)
      end

      reply(conn, %{
        "invoice_number" => "BRZ/26/0X",
        "line_items" => [%{"taxable_value" => 1_000.0}],
        "printed_total_taxable" => 1_000.0,
        "printed_grand_total" => 1_180.0
      })
    end)

    task =
      Task.async(fn ->
        Req.Test.allow(MistralChat, test_pid, self())

        Segmented.extract(:purchase, t, Enum.map(1..3, &segment([&1])),
          on_segment: fn done, total -> send(test_pid, {:report, done, total}) end
        )
      end)

    assert_receive {:stuck, blocked}, 2_000
    # The first segment is still mid-call; the two behind it have landed and
    # said so.
    assert_receive {:report, 1, 3}, 2_000
    assert_receive {:report, 2, 3}, 2_000

    send(blocked, :release)
    result = Task.await(task, 5_000)

    assert_receive {:report, 3, 3}, 2_000
    assert length(result.pages) == 3
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
