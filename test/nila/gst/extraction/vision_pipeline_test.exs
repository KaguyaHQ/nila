defmodule Nila.Gst.Extraction.VisionPipelineTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.VisionPipeline
  alias Nila.Gst.Purchase.Books
  alias Nila.PdfFixtures

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
      "printed_cgst" => 90.0,
      "printed_sgst" => 90.0,
      "printed_igst" => nil,
      "printed_total_tax" => 180.0,
      "printed_additional_charges" => nil,
      "printed_rounding_adjustment" => nil,
      "printed_grand_total" => 1_180.0,
      "reverse_charge" => nil
    }
  end

  defp sales_invoice do
    invoice()
    |> Map.put("seller", %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"})
    |> Map.put("buyer", %{"name" => "Customer", "gstin" => "33AAHFC9048D1Z4"})
    |> Map.merge(%{
      "recipient_registration" => "registered",
      "place_of_supply" => "Tamil Nadu",
      "document_status" => "active",
      "supply_type" => "taxable"
    })
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
    [_system, %{"content" => extraction_content}] = extraction_request["messages"]
    assert Enum.count(extraction_content, &(&1["type"] == "image_url")) == 2
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
