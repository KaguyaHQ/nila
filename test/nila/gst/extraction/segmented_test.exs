defmodule Nila.Gst.Extraction.SegmentedTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
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
    invoice =
      Map.update(invoice, "line_items", [], fn lines ->
        Enum.map(lines, &Map.put_new(&1, "repeat_count", 1))
      end)

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
    Taxable 1,000.00  CGST 9% 90.00  SGST 9% 90.00
    Total tax 180.00
    Grand total 1,180.00
    """
  end

  test "one call carries exactly one invoice, and its pages are a fact not a guess" do
    t = transcription([{5, invoice_page(5)}, {6, "continued\nGrand total 1,180.00"}])

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
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

  test "unobserved printed candidates are discarded and retained in the audit" do
    text = """
    TAX INVOICE INV-1
    | Item | Value | CGST | SGST | Total |
    | Service | 1,000.00 | 90.00 | 90.00 | 1,180.00 |
    """

    t = transcription([{1, text}])

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      reply(conn, %{
        "invoice_number" => "INV-1",
        "line_items" => [
          %{
            "quantity" => 2,
            "printed_line_amount" => 1_000,
            "printed_line_total" => 1_180,
            "printed_taxable_value" => 1_000,
            "line_amount_tax_inclusion" => "exclusive",
            "cgst_rate" => 9,
            "cgst_amount" => 90,
            "sgst_rate" => 9,
            "sgst_amount" => 90
          }
        ],
        "printed_cgst" => 3_105,
        "printed_sgst" => 3_105,
        "printed_total_tax" => 180,
        "printed_grand_total" => 1_180
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:sales, t, segment([1], "INV-1"))

    assert artifact["data"]["printed_cgst"] == nil
    assert artifact["data"]["printed_sgst"] == nil
    assert artifact["data"]["printed_total_tax"] == nil
    assert get_in(artifact, ["data", "line_items", Access.at(0), "quantity"]) == nil
    assert get_in(artifact, ["data", "line_items", Access.at(0), "printed_taxable_value"]) == nil

    assert %{
             "field" => "printed_total_tax",
             "from" => 180,
             "to" => nil,
             "basis" => "value_absent_from_source"
           } in artifact["repairs"]

    assert Enum.any?(artifact["repairs"], fn repair ->
             repair["field"] == "line_items[0].printed_taxable_value" and
               repair["from"] == 1_000 and repair["to"] == nil and
               repair["basis"] == "redundant_with_arithmetically_exclusive_line_amount"
           end)

    assert Enum.any?(artifact["repairs"], fn repair ->
             repair["field"] == "printed_cgst" and repair["from"] == 3_105 and
               repair["to"] == nil
           end)

    assert artifact["verification"] == %{
             "status" => "verified",
             "flags" => [],
             "failed_checks" => []
           }
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

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      schema = Jason.decode!(body)["response_format"]["json_schema"]["schema"]
      properties = schema["properties"]

      assert properties["recipient_registration"]["enum"] ==
               ["registered", "unregistered", "unknown"]

      assert Map.has_key?(properties, "supplier")
      assert Map.has_key?(properties, "bill_to")
      assert Map.has_key?(properties, "ship_to")
      refute Map.has_key?(properties, "printed_place_of_supply")
      refute Map.has_key?(properties, "place_of_supply")
      refute Map.has_key?(properties, "delivery_address")
      assert Map.has_key?(properties, "document_status")
      assert Map.has_key?(properties, "supply_type")
      line_schema = get_in(properties, ["line_items", "items"])
      line_properties = line_schema["properties"]
      assert Map.has_key?(line_properties, "item_name")
      assert Map.has_key?(line_properties, "printed_unit_price")
      assert Map.has_key?(line_properties, "printed_line_amount")
      assert Map.has_key?(line_properties, "printed_line_total")
      assert Map.has_key?(line_properties, "printed_taxable_value")
      assert line_properties["repeat_count"]["minimum"] == 1
      assert line_properties["repeat_count"]["maximum"] == 1_000
      assert "repeat_count" in line_schema["required"]

      assert line_properties["printed_taxable_value"]["description"] =~
               "Do not duplicate printed_line_amount"

      assert line_properties["line_amount_tax_inclusion"]["enum"] ==
               ["inclusive", "exclusive", "unknown"]

      assert line_properties["line_amount_tax_inclusion"]["description"] =~
               "labels, table structure or visible same-row arithmetic"

      [_system, user] = Jason.decode!(body)["messages"]
      assert user["content"] =~ "copy its printed label, rate and amount"
      assert user["content"] =~ "Never use arithmetic to populate any extracted numeric field"
      assert user["content"] =~ "line_amount_tax_inclusion is an inferred semantic field"
      assert user["content"] =~ "Never duplicate printed_line_amount"
      assert user["content"] =~ "footer captions and amount-in-words labels"
      assert user["content"] =~ "Never infer a tax head"
      assert user["content"] =~ "Never select, combine or sum tax-rate or slab-summary rows"
      assert user["content"] =~ "return one line item with repeat_count equal to"
      assert user["content"] =~ "Never combine rows that differ"

      assert properties["printed_total_taxable"]["description"] =~
               "Return null when no invoice-level aggregate is printed"

      assert properties["printed_additional_charges"]["description"] =~
               "explicitly places that amount after GST"

      reply(conn, %{
        "document_type" => "debit_note",
        "recipient_registration" => "registered",
        "document_status" => "active",
        "supply_type" => "taxable",
        "invoice_number" => "CDN-000001",
        "invoice_date" => "10/08/2026",
        "supplier" => %{
          "name" => "Seller",
          "gstin" => "33AEWPH4158J1Z3",
          "address" => nil,
          "state_code" => "33"
        },
        "bill_to" => %{
          "name" => "Buyer",
          "gstin" => "29AAVCS8021P1ZB",
          "address" => nil,
          "state_code" => "29"
        },
        "ship_to" => nil,
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

  test "a purchase credit note is classified without turning positive amounts negative" do
    text = """
    CREDIT NOTE CN-NILA-PUR-001
    Date 10/08/2026
    Supplier GSTIN 33CPWPV2650A1ZQ
    Buyer GSTIN 22AAAAA0000A1Z5
    SAC 998719 Taxable 20,000.00 IGST 18% 3,600.00 Total 23,600.00
    """

    t = transcription([{1, text}])

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      properties = payload["response_format"]["json_schema"]["schema"]["properties"]
      [_system, user] = payload["messages"]

      assert properties["document_type"]["enum"] ==
               ["invoice", "credit_note", "debit_note"]

      assert user["content"] =~ "Keep every printed amount positive"

      reply(conn, %{
        "document_type" => "credit_note",
        "invoice_number" => "CN-NILA-PUR-001",
        "invoice_date" => "10/08/2026",
        "seller" => %{"name" => "Supplier", "gstin" => "33CPWPV2650A1ZQ"},
        "buyer" => %{"name" => "Buyer", "gstin" => "22AAAAA0000A1Z5"},
        "line_items" => [
          %{
            "hsn_sac" => "998719",
            "printed_taxable_value" => 20_000,
            "igst_rate" => 18,
            "igst_amount" => 3_600
          }
        ],
        "printed_total_taxable" => 20_000,
        "printed_total_tax" => 3_600,
        "printed_grand_total" => 23_600
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([1], "CN-NILA-PUR-001"))

    assert artifact["data"]["document_type"] == "credit_note"
    assert artifact["data"]["printed_grand_total"] == 23_600
    assert artifact["document"]["credit_note"]
    assert artifact["document"]["extracted_type"] == "credit_note"
  end

  test "a fabricated total is caught before the artifact leaves the stage" do
    t = transcription([{1, invoice_page(1)}])

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
      reply(conn, %{
        "invoice_number" => "BRZ/26/01",
        "line_items" => [
          %{
            "printed_line_amount" => 1_000.0,
            "line_amount_tax_inclusion" => "exclusive",
            "cgst_rate" => 9.0,
            "cgst_amount" => 90.0,
            "sgst_rate" => 9.0,
            "sgst_amount" => 90.0
          }
        ],
        # 9,999 appears nowhere on the page.
        "printed_total_taxable" => 9_999.0,
        "printed_total_tax" => 180.0,
        "printed_grand_total" => 1_180.0
      })
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([1]))

    assert artifact["data"]["printed_total_taxable"] == nil
    assert artifact["verification"]["status"] == "verified"

    assert %{
             "field" => "printed_total_taxable",
             "from" => 9_999.0,
             "to" => nil,
             "basis" => "value_absent_from_source"
           } in artifact["repairs"]
  end

  test "a segment too dense for one output budget is split before the call, not after" do
    rows = Enum.map_join(1..100, "\n", fn _n -> "| Item | 1 | 10.00 |" end)
    t = transcription([{1, "TAX INVOICE\n" <> rows}, {2, rows <> "\nGrand total 2,000.00"}])

    # 200 rows over two pages exceeds the per-call row limit, so the invoice is
    # read in two calls and merged in code — the escape hatch that only exists
    # because the input is text and therefore measurable in advance.
    assert Segmented.row_limit() < 200

    Req.Test.expect(OpenAICompatibleChat, 2, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [_system, user] = Jason.decode!(body)["messages"]

      if user["content"] =~ "--- page 1 ---" do
        reply(conn, %{
          "invoice_number" => "BIG-1",
          "line_items" => [
            %{"item_name" => "First page", "taxable_value" => 10.0, "repeat_count" => 100}
          ],
          "printed_total_taxable" => nil
        })
      else
        assert user["content"] =~ "CONTINUATION"

        reply(conn, %{
          "invoice_number" => nil,
          "line_items" => [
            %{"item_name" => "Second page", "taxable_value" => 10.0, "repeat_count" => 100}
          ],
          "printed_total_taxable" => 2_000.0
        })
      end
    end)

    {:ok, artifact} = Segmented.extract_segment(:purchase, t, segment([1, 2], "BIG-1"))

    lines = artifact["data"]["line_items"]
    assert length(lines) == 200
    assert Enum.at(lines, 99)["item_name"] == "First page"
    assert Enum.at(lines, 100)["item_name"] == "Second page"
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
      data = %{
        "supplier" => %{"gstin" => @damaged},
        "bill_to" => %{"gstin" => @damaged}
      }

      {repaired, repairs} = Segmented.repair_gstins(data, :sales, @client)

      assert repaired["supplier"]["gstin"] == @client
      assert repaired["bill_to"]["gstin"] == @damaged
      assert [%{"field" => "supplier.gstin", "basis" => "known_client"}] = repairs
    end
  end

  @tag :capture_log
  test "one failed segment prevents partial extraction from leaving the stage" do
    t = transcription([{1, invoice_page(1)}, {2, invoice_page(2)}])

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(body)["messages"] |> List.last() |> Map.fetch!("content")

      if content =~ "--- page 2 ---" do
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
      else
        reply(conn, %{
          "invoice_number" => "BRZ/26/01",
          "line_items" => [%{"taxable_value" => 1_000.0}],
          "printed_total_taxable" => 1_000.0,
          "printed_grand_total" => 1_180.0
        })
      end
    end)

    assert {:error, {:invoice_segments_failed, [failure]}, audit} =
             Segmented.extract(:purchase, t, [segment([1]), segment([2])], max_retries: 0)

    assert failure.pages == [2]
    assert audit.failures == [failure]
  end

  # A rate-limited segment sits in backoff for half a minute. Ordered delivery
  # would hold every later segment's report behind it, so the bar reads zero
  # while the rest of the pile is already read — which is what the operator
  # saw, and what sent them looking for a hung screen.
  test "a segment stuck in backoff does not hold back the count for the rest" do
    test_pid = self()
    t = transcription(Enum.map(1..3, &{&1, invoice_page(&1)}))

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
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
        Req.Test.allow(OpenAICompatibleChat, test_pid, self())

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

    Req.Test.expect(OpenAICompatibleChat, fn conn ->
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
