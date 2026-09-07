defmodule Nila.Gst.Extraction.VisionPipelineTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Segmented
  alias Nila.Gst.Extraction.VisionPipeline
  alias Nila.Gst.Purchase.Books
  alias Nila.Gst.Sales.Gstr1
  alias Nila.PdfFixtures

  @line_item_fields ~w(
    item_name description hsn_sac quantity uom printed_unit_price discount_rate
    discount_amount printed_line_amount printed_line_total printed_taxable_value
    line_amount_tax_inclusion printed_tax_components repeat_count
  )

  defp chat_response(content) do
    %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
      "usage" => %{"total_tokens" => 40}
    }
  end

  defp invoice(number \\ "INV-1") do
    %{
      "document_type" => "invoice",
      "invoice_number" => number,
      "invoice_date" => "08/10/2025",
      "seller" => %{
        "name" => "Supplier",
        "gstin" => "32AAMFD7558A1ZL",
        "address" => "Kerala"
      },
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "delivery_address" => nil,
      "line_items" => [],
      "printed_subtotal_before_discount" => nil,
      "printed_discount_amount" => nil,
      "printed_total_taxable" => 1_000.0,
      "printed_tax_totals" => [
        %{"printed_label" => "CGST", "printed_amount" => 90.0},
        %{"printed_label" => "SGST", "printed_amount" => 90.0},
        %{"printed_label" => "Total Tax", "printed_amount" => 180.0}
      ],
      "printed_additional_charges" => nil,
      "printed_rounding_adjustment" => nil,
      "printed_grand_total" => 1_180.0,
      "reverse_charge" => nil
    }
  end

  defp sales_invoice do
    invoice()
    |> Map.drop(["seller", "buyer", "delivery_address"])
    |> Map.merge(%{
      "supplier" => %{
        "name" => "Breeze",
        "gstin" => "33AEWPH4158J1Z3",
        "address" => "Chennai",
        "state_code" => "33"
      },
      "bill_to" => %{
        "name" => "Customer",
        "gstin" => "33AAHFC9048D1Z4",
        "address" => "Chennai",
        "state_code" => "33"
      },
      "ship_to" => nil,
      "recipient_registration" => "registered",
      "document_status" => "active",
      "supply_type" => "taxable",
      "tax_payment" => "not_applicable"
    })
  end

  defp line_item(overrides) do
    Map.merge(
      %{
        "item_name" => "CAMC for Chiller",
        "description" => "CAMC for Chiller",
        "hsn_sac" => "998719",
        "quantity" => 1,
        "uom" => nil,
        "printed_unit_price" => 47_500,
        "discount_rate" => nil,
        "discount_amount" => nil,
        "printed_line_amount" => 47_500,
        "printed_line_total" => 56_050,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "exclusive",
        "printed_tax_components" => [
          %{"printed_label" => "CGST", "printed_rate" => 9, "printed_amount" => 4_275},
          %{"printed_label" => "SGST", "printed_rate" => 9, "printed_amount" => 4_275}
        ],
        "repeat_count" => 1
      },
      overrides
    )
  end

  defp positional_line_item(overrides) do
    line = line_item(overrides)
    Enum.map(@line_item_fields, &Map.fetch!(line, &1))
  end

  defp stub(labels, extracted_invoice \\ invoice()) do
    test_pid = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      name = get_in(request, ["response_format", "json_schema", "name"])
      send(test_pid, {:vision_request, name, request})

      content =
        if name == "nila_packet_page_labels", do: %{"pages" => labels}, else: extracted_invoice

      Req.Test.json(conn, chat_response(content))
    end)
  end

  test "segments a PDF once and extracts one artifact from the resulting page group" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
      %{"page" => 2, "label" => "continuation", "invoice_no" => nil, "reason" => nil}
    ])

    test_pid = self()

    per_call = fn metadata, call ->
      send(test_pid, {:stage, metadata})
      call.()
    end

    assert {:ok, result} =
             VisionPipeline.extract(:purchase, PdfFixtures.pdf(2),
               filename: "packet.pdf",
               client_gstin: "33AEWPH4158J1Z3",
               per_call: per_call,
               on_progress: &send(test_pid, &1)
             )

    assert [%{"source_pages" => [1, 2]} = artifact] = result.pages
    assert artifact["data"]["invoice_number"] == "INV-1"
    assert artifact["image"] == "page_01.jpg"
    assert artifact["verification"]["status"] == "unverifiable"
    assert map_size(result.images) == 2
    assert result.unaccounted_pages == []

    assert %{"invoices" => [%{"taxable_paise" => 100_000, "total_paise" => 118_000}]} =
             Books.normalize(result.pages)

    assert_receive {:stage, %{stage: "vision_segmentation", pages: 2}}
    assert_receive {:stage, %{stage: "vision_extraction", segments: 1}}
    assert_receive {:progress, %{stage: :segmenting, done: 2, total: 2}}
    assert_receive {:progress, %{stage: :reading, done: 1, total: 1}}

    assert_receive {:vision_request, "nila_packet_page_labels", segmentation_request}
    [_system, %{"content" => segmentation_content}] = segmentation_request["messages"]
    assert Enum.count(segmentation_content, &(&1["type"] == "image_url")) == 2

    assert_receive {:vision_request, "nila_direct_purchase_invoice", extraction_request}

    line_schema =
      get_in(extraction_request, [
        "response_format",
        "json_schema",
        "schema",
        "properties",
        "line_items",
        "items"
      ])

    assert line_schema["type"] == "array"
    assert line_schema["items"] == false
    assert line_schema["minItems"] == length(@line_item_fields)
    assert length(line_schema["prefixItems"]) == length(@line_item_fields)

    component_schema = Enum.at(line_schema["prefixItems"], 12)
    assert component_schema["type"] == "array"

    assert MapSet.new(component_schema["items"]["required"]) ==
             MapSet.new(~w(printed_amount printed_label printed_rate))

    assert component_schema["description"] =~ "Copy each label"

    root_properties = extraction_request["response_format"]["json_schema"]["schema"]["properties"]
    assert Map.has_key?(root_properties, "printed_tax_totals")
    assert root_properties["line_items"]["description"] =~ "append it to that item's description"

    assert MapSet.new(root_properties["printed_tax_totals"]["items"]["required"]) ==
             MapSet.new(~w(printed_amount printed_label))

    refute Map.has_key?(root_properties, "printed_cgst")
    refute Map.has_key?(root_properties, "printed_sgst")
    refute Map.has_key?(root_properties, "printed_igst")

    [_system, %{"content" => extraction_content}] = extraction_request["messages"]
    assert Enum.count(extraction_content, &(&1["type"] == "image_url")) == 2
    instruction = hd(extraction_content)["text"]
    assert instruction =~ "[#{Enum.join(@line_item_fields, ", ")}]"
    assert instruction =~ "Preserve nulls so every row has exactly"
    assert instruction =~ "14 values"
  end

  test "one failed invoice call rejects the whole packet and preserves completed responses" do
    test_pid = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      name = get_in(request, ["response_format", "json_schema", "name"])

      case name do
        "nila_packet_page_labels" ->
          Req.Test.json(
            conn,
            chat_response(%{
              "pages" => [
                %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
                %{"page" => 2, "label" => "start", "invoice_no" => "INV-2", "reason" => nil}
              ]
            })
          )

        "nila_direct_purchase_invoice" ->
          [_system, %{"content" => content}] = request["messages"]
          marker = Enum.find(content, &(&1["type"] == "text" and &1["text"] =~ "PHYSICAL PAGE"))

          if marker["text"] == "PHYSICAL PAGE 2" do
            conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad page"})
          else
            Req.Test.json(conn, chat_response(invoice()))
          end
      end
    end)

    per_call = fn metadata, call ->
      result = call.()
      send(test_pid, {:stage_result, metadata.stage, result})
      result
    end

    assert {:error, {:invoice_segments_failed, [%{pages: [2]}]}} =
             VisionPipeline.extract(:purchase, PdfFixtures.pdf(2),
               filename: "packet.pdf",
               max_retries: 0,
               per_call: per_call
             )

    assert_receive {:stage_result, "vision_extraction", {:error, _reason, audit}}
    assert length(audit.metadata["responses"]) == 2
    assert audit.metadata["failures"] != []
  end

  test "rejects a segmentation response that does not conserve every physical page" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil}
    ])

    assert {:error, {:page_conservation, [1, 2], [1]}} =
             VisionPipeline.extract(:purchase, PdfFixtures.pdf(2), filename: "packet.pdf")

    assert_receive {:vision_request, "nila_packet_page_labels", _request}
    refute_receive {:vision_request, "nila_direct_purchase_invoice", _request}
  end

  test "sales uses the sales schema and preserves direct-vision document markers" do
    stub(
      [%{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil}],
      Map.put(sales_invoice(), "reverse_charge", true)
    )

    assert {:ok, %{pages: [artifact]}} =
             VisionPipeline.extract(:sales, <<0xFF, 0xD8, 0xFF, 0xD9>>,
               filename: "sale.jpg",
               client_gstin: "33AEWPH4158J1Z3"
             )

    assert artifact["document"] == %{
             "credit_note" => false,
             "debit_note" => false,
             "export" => false,
             "reverse_charge" => true,
             "extracted_type" => "invoice"
           }

    assert artifact["data"]["recipient_registration"] == "registered"
  end

  test "fixed-segment extraction skips discovery but retains the production vision path" do
    stub([], sales_invoice())

    assert {:ok, %{pages: [artifact]}} =
             VisionPipeline.extract_fixed_segments(
               :sales,
               <<0xFF, 0xD8, 0xFF, 0xD9>>,
               [[1]],
               filename: "sale.jpg",
               client_gstin: "33AEWPH4158J1Z3"
             )

    assert artifact["data"]["invoice_number"] == "INV-1"
    assert_receive {:vision_request, "nila_direct_sales_invoice", _request}
    refute_receive {:vision_request, "nila_packet_page_labels", _request}
  end

  test "expands repeated rows before verification and sales accounting" do
    extracted =
      sales_invoice()
      |> put_in(
        ["bill_to"],
        %{
          "name" => "Customer",
          "gstin" => "29AAVCS8021P1ZB",
          "address" => "Karnataka",
          "state_code" => "29"
        }
      )
      |> Map.put("line_items", [positional_line_item(%{"repeat_count" => 10})])
      |> Map.merge(%{
        "printed_subtotal_before_discount" => 475_000,
        "printed_total_taxable" => 475_000,
        "printed_tax_totals" => [
          %{
            "printed_label" => "CGST",
            "printed_amount" => 42_750
          },
          %{
            "printed_label" => "SGST",
            "printed_amount" => 42_750
          },
          %{
            "printed_label" => "Total Tax",
            "printed_amount" => 85_500
          }
        ],
        "printed_grand_total" => 560_500
      })

    stub(
      [%{"page" => 1, "label" => "start", "invoice_no" => "27/2026-27", "reason" => nil}],
      extracted
    )

    assert {:ok, %{pages: [artifact]}} =
             VisionPipeline.extract(:sales, <<0xFF, 0xD8, 0xFF, 0xD9>>, filename: "sale.jpg")

    assert lines = artifact["data"]["line_items"]
    assert length(lines) == 10
    assert Enum.all?(lines, &(&1["item_name"] == "CAMC for Chiller"))
    assert Enum.all?(lines, &(not Map.has_key?(&1, "repeat_count")))
    assert Enum.all?(lines, &(&1["cgst_rate"] == 9 and &1["sgst_rate"] == 9))
    assert artifact["verification"]["flags"] == []

    normalized = Gstr1.normalize_invoice(artifact)
    assert Gstr1.extracted_totals(normalized) == %{taxable: 475_000, tax: 85_500}
    assert normalized["printed_grand_total"] == 560_500

    assert Enum.all?(
             normalized["line_items"],
             &(&1["printed_tax_components"] == [
                 %{
                   "printed_label" => "CGST",
                   "printed_rate" => 9,
                   "printed_amount" => 4_275
                 },
                 %{
                   "printed_label" => "SGST",
                   "printed_rate" => 9,
                   "printed_amount" => 4_275
                 }
               ])
           )
  end

  test "does not collapse distinct or non-consecutive rows" do
    data = %{
      "line_items" => [
        line_item(%{"item_name" => "First", "repeat_count" => 1}),
        line_item(%{"item_name" => "Second", "repeat_count" => 1}),
        line_item(%{"item_name" => "First", "repeat_count" => 1})
      ]
    }

    assert %{"line_items" => lines} = Segmented.expand_repeated_line_items(data)
    assert Enum.map(lines, & &1["item_name"]) == ["First", "Second", "First"]
    assert Enum.all?(lines, &(not Map.has_key?(&1, "repeat_count")))
  end

  test "rejects a repeat count outside the schema boundary" do
    data = %{"line_items" => [line_item(%{"repeat_count" => 1_001})]}

    assert_raise ArgumentError, "invalid repeat_count: 1001", fn ->
      Segmented.expand_repeated_line_items(data)
    end
  end

  test "reports model-proposed non-invoices as unaccounted without independent proof" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
      %{"page" => 2, "label" => "non_invoice", "invoice_no" => nil, "reason" => "receipt"}
    ])

    assert {:ok, result} =
             VisionPipeline.extract(:purchase, PdfFixtures.pdf(2), filename: "packet.pdf")

    assert result.unaccounted_pages == [2]
  end

  test "sends an uploaded image directly and retains it as review evidence" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil}
    ])

    jpeg = <<0xFF, 0xD8, 0xFF, 0xD9>>

    assert {:ok, %{pages: [artifact], images: %{"page_01.jpg" => ^jpeg}}} =
             VisionPipeline.extract(:purchase, jpeg, filename: "scan.jpg")

    assert artifact["source_pages"] == [1]
    assert artifact["image"] == "page_01.jpg"

    assert_receive {:vision_request, "nila_packet_page_labels", request}
    [_system, %{"content" => content}] = request["messages"]
    image = Enum.find(content, &(&1["type"] == "image_url"))
    assert image["image_url"]["url"] =~ "data:image/jpeg;base64,"
  end

  test "bounds whole-packet segmentation before submitting images to the provider" do
    assert {:error, {:vision_packet_too_many_pages, 101, 100}} =
             VisionPipeline.extract(:purchase, PdfFixtures.pdf(101), filename: "packet.pdf")
  end

  test "rejects image formats the gateway and evidence UI cannot safely preserve" do
    assert {:error, {:unsupported_content_type, "image/heic"}} =
             VisionPipeline.extract(:purchase, "heic", filename: "scan.heic")
  end
end
