defmodule Nila.Gst.MistralOCRTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.MistralOCR
  alias Nila.Gst.PurchaseExtractor

  test "sends the original PDF to pinned OCR 4 with annotations, blocks, and confidence" do
    pdf = "%PDF-1.7 original bytes"

    Req.Test.expect(MistralOCR, fn conn ->
      assert conn.request_path == "/v1/ocr"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-mistral-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "mistral-ocr-4-0"
      assert payload["table_format"] == "markdown"
      assert payload["include_blocks"] == true
      assert payload["confidence_scores_granularity"] == "word"
      assert payload["pages"] == [0, 1]
      assert payload["document"]["type"] == "document_url"

      data_uri = payload["document"]["document_url"]
      assert String.starts_with?(data_uri, "data:application/pdf;base64,")
      encoded = String.replace_prefix(data_uri, "data:application/pdf;base64,", "")
      assert Base.decode64!(encoded) == pdf

      annotation = payload["document_annotation_format"]["json_schema"]
      assert annotation["strict"] == true
      assert get_in(annotation, ["schema", "properties", "invoices", "type"]) == "array"

      invoice_properties =
        get_in(annotation, ["schema", "properties", "invoices", "items", "properties"])

      assert Map.has_key?(invoice_properties, "printed_subtotal_before_discount")
      assert Map.has_key?(invoice_properties, "printed_discount_amount")
      assert Map.has_key?(invoice_properties, "printed_total_taxable")
      assert Map.has_key?(invoice_properties, "printed_rounding_adjustment")

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-ocr-123")
      |> Req.Test.json(response())
    end)

    assert {:ok, result} =
             PurchaseExtractor.MistralOCR.extract(pdf,
               filename: "bills.pdf",
               content_type: "application/pdf",
               pages: [0, 1]
             )

    assert result.images == %{}
    assert [artifact] = result.pages
    assert artifact["page"] == 2
    assert artifact["source_pages"] == [2]
    assert artifact["source_attribution"]["status"] == "verified"
    assert artifact["confidence"]["source_attribution"] == 1.0
    assert artifact["confidence"]["ocr_minimum"] == 0.77
    assert artifact["confidence"]["ocr_average"] == 0.98
    assert artifact["data"]["invoice_number"] == "DPS-0072"
    assert artifact["data"]["is_invoice"] == true
    refute Map.has_key?(artifact, "markdown")
    refute Map.has_key?(artifact, "blocks")

    assert result.audit.provider_request_id == "req-ocr-123"
    assert result.audit.http_status == 200
    assert result.audit.source_page_count == 2
    assert result.audit.usage == %{"pages_processed" => 2}
    assert Jason.decode!(result.audit.raw_response)["model"] == "mistral-ocr-4-0"
  end

  test "sends an image unchanged as an image_url" do
    image = <<0xFF, 0xD8, 0xFF, 0x00>>

    Req.Test.expect(MistralOCR, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["document"]["type"] == "image_url"

      encoded =
        String.replace_prefix(payload["document"]["image_url"], "data:image/jpeg;base64,", "")

      assert Base.decode64!(encoded) == image
      Req.Test.json(conn, response())
    end)

    assert {:ok, _result} =
             PurchaseExtractor.MistralOCR.extract(image,
               filename: "phone.jpg",
               content_type: "image/jpeg"
             )
  end

  test "returns the failed provider response for audit without fallback" do
    Req.Test.expect(MistralOCR, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Plug.Conn.put_resp_header("x-request-id", "req-failed")
      |> Req.Test.json(%{"message" => "bad schema"})
    end)

    assert {:error, {:mistral_ocr_failed, 422, %{"message" => "bad schema"}}, audit} =
             PurchaseExtractor.MistralOCR.extract("%PDF",
               filename: "bad.pdf",
               content_type: "application/pdf"
             )

    assert audit.provider_request_id == "req-failed"
    assert audit.http_status == 422
    assert Jason.decode!(audit.raw_response) == %{"message" => "bad schema"}
  end

  defp response do
    invoice = %{
      "source_pages" => [2],
      "invoice_number" => "DPS-0072",
      "invoice_date" => "08-10-2025",
      "seller" => %{"name" => "Dawn Power", "gstin" => "32AAMFD7558A1ZL"},
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "line_items" => [
        %{
          "description" => "Battery",
          "hsn_sac" => "8507",
          "quantity" => 1,
          "taxable_value" => 17_000,
          "igst_rate" => 18,
          "igst_amount" => 3060
        }
      ],
      "printed_total_taxable" => 17_000,
      "printed_total_tax" => 3060,
      "printed_grand_total" => 20_060
    }

    %{
      "model" => "mistral-ocr-4-0",
      "pages" => [
        %{
          "index" => 0,
          "markdown" => "cover",
          "dimensions" => %{"width" => 100, "height" => 200},
          "blocks" => []
        },
        %{
          "index" => 1,
          "markdown" => "[tbl-0.md](tbl-0.md)",
          "tables" => [
            %{"content" => "Invoice DPS-0072 GSTIN 32AAMFD7558A1ZL total 20,060"}
          ],
          "dimensions" => %{"width" => 100, "height" => 200},
          "blocks" => [],
          "confidence_scores" => %{
            "minimum_page_confidence_score" => 0.77,
            "average_page_confidence_score" => 0.98
          }
        }
      ],
      "document_annotation" => %{"invoices" => [invoice]},
      "usage_info" => %{"pages_processed" => 2}
    }
  end
end
