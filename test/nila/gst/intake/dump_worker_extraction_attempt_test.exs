defmodule Nila.Gst.Intake.DumpWorkerExtractionAttemptTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Intake.{DumpWorker, Dumps, ExtractionAttempts}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.PdfFixtures
  alias Nila.Storage

  defmodule Provider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "mistral"
    def model, do: "mistral-ocr-4-0"

    @impl true
    def extract(_bytes, _opts) do
      {:ok,
       %{
         pages: [
           %{
             "page" => 1,
             "source_pages" => [1],
             "source_attribution" => %{"status" => "verified", "candidate_pages" => [1]},
             "image" => nil,
             "confidence" => %{"source_attribution" => 1.0},
             "data" => %{
               "is_invoice" => true,
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
                   "igst_amount" => 3060
                 }
               ],
               "printed_grand_total" => 20_060
             }
           }
         ],
         images: %{},
         audit: %{
           provider_request_id: "req-worker",
           http_status: 200,
           source_page_count: 1,
           usage: %{"pages_processed" => 1},
           raw_response: ~s({"model":"mistral-ocr-4-0","pages":[{"index":0}]})
         }
       }}
    end
  end

  test "records and stores the provider call before deriving the dump" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, Provider)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/original.pdf"
    {:ok, _stored} = Storage.put(key, "%PDF-1.7 test")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    assert [attempt] = ExtractionAttempts.list_for_dump(dump.id)
    assert attempt.status == "succeeded"
    assert attempt.provider == "mistral"
    assert attempt.model == "mistral-ocr-4-0"
    assert attempt.provider_request_id == "req-worker"
    assert attempt.worker_attempt == 1
    assert attempt.source_page_count == 1
    assert attempt.response_artifact_key

    assert {:ok, compressed} = Storage.get(attempt.response_artifact_key)
    assert Jason.decode!(:zstd.decompress(compressed))["model"] == "mistral-ocr-4-0"

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert extracted.status == "extracted"
    assert [invoice] = extracted.invoices
    assert invoice["invoice_number"] == "DPS-0072"
    assert invoice["pages"] == [1]
  end

  test "the segmented pipeline records one attempt per stage and confesses unread pages" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, Nila.Gst.Extraction.Purchase.MistralOCR)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    # One OCR call for the whole packet, annotation off: pages 1-8 are one bill,
    # 9-13 another, and page 14 is a page nothing on it identifies.
    Req.Test.stub(Mistral, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-transcription")
      |> Req.Test.json(transcription_response())
    end)

    Req.Test.stub(Nila.Gst.Extraction.Providers.MistralChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case get_in(request, ["response_format", "json_schema", "name"]) do
        "nila_page_label" -> Req.Test.json(conn, label_response(judged_page(request)))
        "nila_purchase_invoice" -> Req.Test.json(conn, invoice_response(judged_pages(request)))
      end
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/packet.pdf"
    {:ok, _stored} = Storage.put(key, PdfFixtures.pdf(14))

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    attempts = ExtractionAttempts.list_for_dump(dump.id)

    assert Enum.all?(attempts, &(&1.status == "succeeded"))

    assert attempts |> Enum.map(& &1.request_metadata["stage"]) |> Enum.sort() ==
             ["discovery", "extraction", "transcription"]

    # The transcription is the text every later stage and every grounding check
    # ran against, so it is the one raw response kept whole.
    assert [transcription] =
             Enum.filter(attempts, &(&1.request_metadata["stage"] == "transcription"))

    assert transcription.provider_request_id == "req-transcription"
    assert transcription.source_page_count == 14
    assert transcription.response_artifact_key

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert Enum.map(extracted.invoices, & &1["invoice_number"]) == ["WIN-1", "WIN-2"]

    # Page 14 was labelled a non-invoice with nothing on it saying so, which is
    # not a verdict the pipeline accepts: the page is reported, not skipped.
    assert extracted.meta["unaccounted_pages"] == [14]
    refute extracted.meta["evidence_unavailable"]

    # Each invoice points at the page it was read from, stored under a basename
    # namespaced by the dump so a straggler's page_01 can never overwrite this one.
    assert [first, second] = extracted.invoices
    assert first["images"] == ["d#{dump.id}_page_01.jpg"]
    assert second["images"] == ["d#{dump.id}_page_09.jpg"]

    assert {:ok, bytes} =
             PurchaseMonths.fetch_evidence(org.id, client.id, "2025-10", hd(first["images"]))

    assert byte_size(bytes) > 0

    {:ok, month} = PurchaseMonths.get_by_period(org.id, client.id, "2025-10")

    assert [flag] = month.summary["document_flags"]
    assert flag["code"] == "pages_unaccounted"
    refute Map.has_key?(flag, "severity")
    assert flag["reason"] =~ "Page 14 of packet.pdf"
  end

  defmodule UnrenderableProvider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "mistral"
    def model, do: "mistral-ocr-4-0"

    @impl true
    def extract(_bytes, _opts) do
      {:ok,
       Map.put(
         Provider.extract(<<>>, []) |> elem(1),
         :evidence_error,
         {:page_render_failed, 1, "boom"}
       )}
    end
  end

  # A packet whose pages will not render still has to produce a register — but
  # the reviewer has to be told, or a month with no pictures looks exactly like
  # a month whose pictures nobody happened to open.
  test "pages that could not be rendered flag the month rather than failing the dump" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, UnrenderableProvider)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/unrenderable.pdf"
    {:ok, _stored} = Storage.put(key, "%PDF-1.7 test")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert extracted.status == "extracted"
    assert [invoice] = extracted.invoices
    assert invoice["invoice_number"] == "DPS-0072"
    assert invoice["images"] == []

    {:ok, month} = PurchaseMonths.get_by_period(org.id, client.id, "2025-10")

    assert [flag] = month.summary["document_flags"]
    assert flag["code"] == "evidence_unavailable"
    refute Map.has_key?(flag, "severity")
    assert flag["reason"] =~ "unrenderable.pdf"
  end

  @bills %{1 => "WIN-1", 9 => "WIN-2"}

  defp transcription_response do
    pages =
      Enum.map(1..14, fn page ->
        %{"index" => page - 1, "markdown" => page_text(page), "blocks" => []}
      end)

    %{"model" => "mistral-ocr-4-0", "pages" => pages, "usage_info" => %{"pages_processed" => 14}}
  end

  defp page_text(14), do: "page 14"

  defp page_text(page) do
    number = if page < 9, do: "WIN-1", else: "WIN-2"

    """
    TAX INVOICE #{number}
    Dawn Power  GSTIN 32AAMFD7558A1ZL
    Breeze  GSTIN 33AEWPH4158J1Z3
    | Battery | 10,000.00 | IGST 1,800.00 |
    Taxable 10,000.00  IGST 1,800.00  Grand total 11,800.00
    """
  end

  # The page a label call is judging is the one the prompt marks; the others are
  # context.
  defp judged_page(request) do
    [_system, user] = request["messages"]
    [page] = Regex.run(~r/JUDGE THIS PAGE — page (\d+)/, user["content"], capture: :all_but_first)
    String.to_integer(page)
  end

  defp judged_pages(request) do
    [_system, user] = request["messages"]

    ~r/--- page (\d+) ---/
    |> Regex.scan(user["content"], capture: :all_but_first)
    |> Enum.map(fn [page] -> String.to_integer(page) end)
  end

  defp label_response(page) do
    label =
      cond do
        # Page 14 carries no marker of what it is, so this verdict does not stand.
        page == 14 -> %{"label" => "non_invoice", "invoice_no" => nil, "reason" => nil}
        Map.has_key?(@bills, page) -> %{"label" => "start", "invoice_no" => @bills[page]}
        true -> %{"label" => "continuation", "invoice_no" => nil}
      end

    chat_response(Map.put_new(label, "reason", nil))
  end

  defp invoice_response(pages) do
    number = if 1 in pages, do: "WIN-1", else: "WIN-2"

    chat_response(%{
      "invoice_number" => number,
      "invoice_date" => "08-10-2025",
      "seller" => %{"name" => "Dawn Power", "gstin" => "32AAMFD7558A1ZL"},
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "line_items" => [
        %{"description" => "Battery", "taxable_value" => 10_000, "igst_amount" => 1_800}
      ],
      "printed_grand_total" => 11_800
    })
  end

  defp chat_response(content) do
    %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
      "usage" => %{"total_tokens" => 100}
    }
  end
end
