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

  test "a windowed extractor records one attempt per window and confesses unread pages" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, Nila.Gst.Extraction.Purchase.MistralOCR)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    Req.Test.stub(Mistral, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      pages = body |> Jason.decode!() |> Map.fetch!("pages") |> Enum.map(&(&1 + 1))

      # Page 14 is read but yields no invoice — the silent-drop failure mode.
      invoice = if 1 in pages, do: {"WIN-1", 1..8}, else: {"WIN-2", 9..13}

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-#{List.first(pages)}")
      |> Req.Test.json(window_response(pages, invoice))
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/windowed.pdf"
    {:ok, _stored} = Storage.put(key, PdfFixtures.pdf(14))

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    attempts = ExtractionAttempts.list_for_dump(dump.id)

    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.status == "succeeded"))

    assert attempts |> Enum.map(& &1.request_metadata["pages"]) |> Enum.sort() == ["1-8", "7-14"]
    assert Enum.all?(attempts, & &1.response_artifact_key)

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert Enum.map(extracted.invoices, & &1["invoice_number"]) == ["WIN-1", "WIN-2"]
    assert extracted.meta["unaccounted_pages"] == [14]

    {:ok, month} = PurchaseMonths.get_by_period(org.id, client.id, "2025-10")

    assert [flag] = month.summary["document_flags"]
    assert flag["code"] == "pages_unaccounted"
    assert flag["severity"] == "review"
    assert flag["reason"] =~ "Page 14 of windowed.pdf"
  end

  defp window_response(pages, {number, invoice_pages}) do
    invoice_pages = Enum.to_list(invoice_pages)

    ocr_pages =
      Enum.map(pages, fn page ->
        text = if page in invoice_pages, do: "Invoice #{number}", else: "page #{page}"
        %{"index" => page - 1, "markdown" => text, "blocks" => []}
      end)

    %{
      "model" => "mistral-ocr-4-0",
      "pages" => ocr_pages,
      "document_annotation" => %{
        "invoices" => [
          %{
            "source_pages" => invoice_pages,
            "invoice_number" => number,
            "invoice_date" => "08-10-2025",
            "seller" => %{"name" => "Dawn Power", "gstin" => "32AAMFD7558A1ZL"},
            "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
            "line_items" => [
              %{"description" => "Battery", "taxable_value" => 10_000, "igst_amount" => 1_800}
            ],
            "printed_grand_total" => 11_800
          }
        ]
      },
      "usage_info" => %{"pages_processed" => length(pages)}
    }
  end
end
