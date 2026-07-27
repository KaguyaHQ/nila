defmodule Nila.Gst.Extraction.WindowedSharedDocumentTest do
  # Flips the `share_document` application env, so this module cannot run
  # alongside the inline-path tests in `Nila.Gst.Extraction.WindowedTest`.
  use ExUnit.Case, async: false

  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Windowed
  alias Nila.PdfFixtures

  setup do
    previous = Application.get_env(:nila, Windowed, [])
    Application.put_env(:nila, Windowed, Keyword.put(previous, :share_document, true))
    on_exit(fn -> Application.put_env(:nila, Windowed, previous) end)
    :ok
  end

  describe "one upload, many windows" do
    test "uploads the document once and points every window at the signed URL" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        send(test_pid, {:hit, conn.method, conn.request_path})
        route(conn)
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(20))

      # Three windows for 20 pages, but exactly one upload and one signed URL.
      assert_receive {:hit, "POST", "/v1/files"}
      assert_receive {:hit, "GET", "/v1/files/file-abc/url"}
      refute_receive {:hit, "POST", "/v1/files"}

      assert length(Enum.filter(hits(), &match?({"POST", "/v1/ocr"}, &1))) == 3

      # The document travels as the signed URL, never as an inlined data URI.
      for payload <- ocr_payloads() do
        assert payload["document"]["document_url"] == "https://files.mistral.test/signed/abc"
        refute payload["document"]["document_url"] =~ "base64"
      end

      assert Enum.map(result.pages, & &1["data"]["invoice_number"]) == ["A-1"]
    end

    test "deletes the upload once the read is done" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        send(test_pid, {:hit, conn.method, conn.request_path})
        route(conn)
      end)

      assert {:ok, _result} = extract(PdfFixtures.pdf(20))

      # A client's invoices do not linger in a third party's file store for the
      # 24h the signed URL would otherwise last.
      assert_receive {:hit, "DELETE", "/v1/files/file-abc"}
    end

    test "a single window is inlined rather than paying for an upload" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        send(test_pid, {:hit, conn.method, conn.request_path})
        route(conn)
      end)

      assert {:ok, _result} = extract(PdfFixtures.pdf(5))

      assert_receive {:hit, "POST", "/v1/ocr"}
      refute_receive {:hit, "POST", "/v1/files"}
      assert [payload] = ocr_payloads()
      assert payload["document"]["document_url"] =~ "data:application/pdf;base64,"
    end

    test "an upload failure falls back to inlining rather than failing the read" do
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        send(test_pid, {:hit, conn.method, conn.request_path})

        case {conn.method, conn.request_path} do
          {"POST", "/v1/files"} ->
            conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "unavailable"})

          _ ->
            route(conn)
        end
      end)

      # The inline path is the one the corpus validated, so degrading to it beats
      # refusing to read.
      assert {:ok, result} = extract(PdfFixtures.pdf(20))
      assert Enum.map(result.pages, & &1["data"]["invoice_number"]) == ["A-1"]

      for payload <- ocr_payloads() do
        assert payload["document"]["document_url"] =~ "data:application/pdf;base64,"
      end
    end

    test "a failed cleanup does not fail an otherwise good read" do
      Req.Test.stub(Mistral, fn conn ->
        case {conn.method, conn.request_path} do
          {"DELETE", _path} -> Req.Test.transport_error(conn, :closed)
          _ -> route(conn)
        end
      end)

      assert {:ok, result} = extract(PdfFixtures.pdf(20))
      assert result.unaccounted_pages != []
    end

    test "share_document: false keeps every window inlined" do
      Application.put_env(:nila, Windowed, share_document: false)
      test_pid = self()

      Req.Test.stub(Mistral, fn conn ->
        send(test_pid, {:hit, conn.method, conn.request_path})
        route(conn)
      end)

      assert {:ok, _result} = extract(PdfFixtures.pdf(20))

      refute_receive {:hit, "POST", "/v1/files"}
      assert Enum.all?(ocr_payloads(), &(&1["document"]["document_url"] =~ "base64"))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp extract(bytes) do
    Windowed.extract(:purchase, bytes, filename: "bills.pdf")
  end

  defp route(conn) do
    case {conn.method, conn.request_path} do
      {"POST", "/v1/files"} ->
        Req.Test.json(conn, %{"id" => "file-abc", "object" => "file", "purpose" => "ocr"})

      {"GET", "/v1/files/file-abc/url"} ->
        Req.Test.json(conn, %{"url" => "https://files.mistral.test/signed/abc"})

      {"DELETE", "/v1/files/file-abc"} ->
        Req.Test.json(conn, %{"id" => "file-abc", "object" => "file", "deleted" => true})

      {"POST", "/v1/ocr"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        send(self(), {:ocr_payload, payload})
        Req.Test.json(conn, ocr_response(payload))
    end
  end

  # Every hit this test process has been told about so far.
  defp hits do
    receive do
      {:hit, method, path} -> [{method, path} | hits()]
    after
      0 -> []
    end
  end

  defp ocr_payloads do
    receive do
      {:ocr_payload, payload} -> [payload | ocr_payloads()]
    after
      0 -> []
    end
  end

  # One invoice on document page 3, so exactly one window claims it and the rest
  # of the pages come back on the ledger.
  defp ocr_response(payload) do
    page_numbers =
      case payload["pages"] do
        # No `pages` subset means a whole-document call, which in these tests is
        # only ever the 5-page fixture.
        nil -> Enum.to_list(1..5)
        pages -> Enum.map(pages, &(&1 + 1))
      end

    pages =
      Enum.map(page_numbers, fn page ->
        %{
          "index" => page - 1,
          "markdown" => "Invoice A-1 GSTIN 33AAACD1234E1ZP total 11800",
          "tables" => [],
          "blocks" => [],
          "confidence_scores" => %{
            "minimum_page_confidence_score" => 0.95,
            "average_page_confidence_score" => 0.99
          }
        }
      end)

    invoices =
      if 3 in page_numbers do
        [
          %{
            "source_pages" => [3],
            "invoice_number" => "A-1",
            "invoice_date" => "08-10-2025",
            "seller" => %{"name" => "Dawn Power", "gstin" => "33AAACD1234E1ZP"},
            "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
            "line_items" => [],
            "printed_grand_total" => 11_800
          }
        ]
      else
        []
      end

    %{
      "model" => "mistral-ocr-4-0",
      "pages" => pages,
      "document_annotation" => %{"invoices" => invoices},
      "usage_info" => %{"pages_processed" => length(page_numbers)}
    }
  end
end
