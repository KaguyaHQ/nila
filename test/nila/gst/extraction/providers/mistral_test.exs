defmodule Nila.Gst.Extraction.Providers.MistralTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.Mistral

  test "transcribes the original PDF without document annotation" do
    pdf = "%PDF-1.7 original bytes"

    Req.Test.expect(Mistral, fn conn ->
      assert conn.request_path == "/v1/ocr"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-mistral-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "mistral-ocr-4-0"
      assert payload["table_format"] == "markdown"
      assert payload["include_blocks"] == true
      assert payload["confidence_scores_granularity"] == "word"
      refute Map.has_key?(payload, "document_annotation_format")
      refute Map.has_key?(payload, "document_annotation_prompt")

      encoded =
        payload["document"]["document_url"]
        |> String.replace_prefix("data:application/pdf;base64,", "")

      assert Base.decode64!(encoded) == pdf

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-ocr-123")
      |> Req.Test.json(%{"pages" => [%{"index" => 0, "markdown" => "invoice"}]})
    end)

    assert {:ok, %{status: 200, headers: headers, body: body}} =
             Mistral.transcribe_raw(pdf, filename: "bills.pdf")

    assert headers["x-request-id"] == ["req-ocr-123"]
    assert Jason.decode!(body)["pages"] == [%{"index" => 0, "markdown" => "invoice"}]
  end

  test "sends an image unchanged as an image URL" do
    image = <<0xFF, 0xD8, 0xFF, 0x00>>

    Req.Test.expect(Mistral, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      encoded =
        payload["document"]["image_url"]
        |> String.replace_prefix("data:image/jpeg;base64,", "")

      assert Base.decode64!(encoded) == image
      Req.Test.json(conn, %{"pages" => [%{"index" => 0, "markdown" => "invoice"}]})
    end)

    assert {:ok, %{status: 200}} = Mistral.transcribe_raw(image, filename: "bill.jpg")
  end

  test "returns a non-success OCR response for the pipeline to classify" do
    Req.Test.expect(Mistral, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"message" => "bad document"})
    end)

    assert {:ok, %{status: 422, body: body}} =
             Mistral.transcribe_raw("%PDF", filename: "bad.pdf")

    assert Jason.decode!(body) == %{"message" => "bad document"}
  end

  test "uploads, signs, and deletes a large document reference" do
    Req.Test.stub(Mistral, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/files"} ->
          Req.Test.json(conn, %{"id" => "file-abc"})

        {"GET", "/v1/files/file-abc/url"} ->
          Req.Test.json(conn, %{"url" => "https://files.mistral.test/signed/abc"})

        {"DELETE", "/v1/files/file-abc"} ->
          Req.Test.json(conn, %{"deleted" => true})
      end
    end)

    assert {:ok, %{file_id: "file-abc", document: document}} =
             Mistral.upload("pdf bytes", "bills.pdf")

    assert document == %{
             type: "document_url",
             document_url: "https://files.mistral.test/signed/abc"
           }

    assert :ok = Mistral.delete("file-abc")
  end
end
