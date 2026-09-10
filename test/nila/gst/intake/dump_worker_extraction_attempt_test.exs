defmodule Nila.Gst.Intake.DumpWorkerExtractionAttemptTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Intake.{DumpWorker, Dumps, ExtractionAttempts}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Storage

  test "provider failures are truncated to the database column limit" do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2026-06", kind: "sales"}
      )

    failed = Dumps.mark_failed(dump, String.duplicate("gateway failure ", 50))

    assert failed.status == "failed"
    assert String.length(failed.error) == 255
  end

  defmodule Provider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "vercel-ai-gateway"
    def model, do: "alibaba/qwen3.7-flash"

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
           raw_response: ~s({"model":"alibaba/qwen3.7-flash","pages":[{"index":0}]})
         }
       }}
    end
  end

  defmodule CrashingProvider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "test"
    def model, do: "test-crash"

    @impl true
    def extract(_bytes, opts) do
      opts
      |> Keyword.fetch!(:on_progress)
      |> then(& &1.({:progress, %{done: 8, total: 14, pages_done: 8, page_count: 14}}))

      raise "provider crashed"
    end
  end

  defmodule MalformedResponseProvider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "test"
    def model, do: "test-malformed"

    @impl true
    def extract(_bytes, _opts) do
      {:error,
       {:invoice_segments_failed,
        [%{pages: [6], reason: {:invalid_text_chat_response, :truncated}}]}}
    end
  end

  defmodule TransientResponseProvider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "test"
    def model, do: "test-transient"

    @impl true
    def extract(_bytes, _opts), do: {:error, {:text_chat_request_failed, :timeout}}
  end

  test "an exhausted malformed response does not make Oban repeat the packet" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, MalformedResponseProvider)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/malformed.pdf"
    {:ok, _stored} = Storage.put(key, "%PDF-1.7 test")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    PurchaseMonths.subscribe(org.id)
    job = %Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1, max_attempts: 3}

    assert :ok = DumpWorker.perform(job)

    assert_receive {:gst_dump_progress, dump_id, _client_id, "2025-10", "purchase",
                    {:failed, {:invoice_segments_failed, _failures}}}

    assert dump_id == dump.id

    refute_receive {:gst_dump_progress, ^dump_id, _client_id, _period, _kind,
                    {:worker_retrying, _attempt, _max_attempts}}

    {:ok, failed_dump} = Dumps.fetch(org.id, dump.id)
    assert failed_dump.status == "failed"
  end

  test "a returned infrastructure failure remains retryable by Oban" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, TransientResponseProvider)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/transient.pdf"
    {:ok, _stored} = Storage.put(key, "%PDF-1.7 test")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    PurchaseMonths.subscribe(org.id)
    job = %Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1, max_attempts: 3}

    assert {:error, {:text_chat_request_failed, :timeout}} = DumpWorker.perform(job)

    assert_receive {:gst_dump_progress, dump_id, _client_id, "2025-10", "purchase",
                    {:worker_retrying, 2, 3}}

    assert dump_id == dump.id
    assert {:ok, %{status: "extracting", error: nil}} = Dumps.fetch(org.id, dump.id)

    final_job = %{job | attempt: 3}
    assert {:error, {:text_chat_request_failed, :timeout}} = DumpWorker.perform(final_job)

    assert_receive {:gst_dump_progress, ^dump_id, _client_id, "2025-10", "purchase",
                    {:failed, {:text_chat_request_failed, :timeout}}}

    assert {:ok, %{status: "failed"}} = Dumps.fetch(org.id, dump.id)
  end

  @tag :capture_log
  test "an intermediate worker failure announces its retry without failing the dump" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, CrashingProvider)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/crashing.pdf"
    {:ok, _stored} = Storage.put(key, "%PDF-1.7 test")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    PurchaseMonths.subscribe(org.id)
    job = %Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1, max_attempts: 3}

    assert_raise RuntimeError, "provider crashed", fn -> DumpWorker.perform(job) end

    assert_receive {:gst_dump_progress, dump_id, client_id, "2025-10", "purchase",
                    {:worker_retrying, 2, 3}}

    assert dump_id == dump.id
    assert client_id == client.id

    {:ok, retrying_dump} = Dumps.fetch(org.id, dump.id)
    assert retrying_dump.status == "extracting"
    assert retrying_dump.error == nil
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
    assert attempt.provider == "vercel-ai-gateway"
    assert attempt.model == "alibaba/qwen3.7-flash"
    assert attempt.provider_request_id == "req-worker"
    assert attempt.worker_attempt == 1
    assert attempt.source_page_count == 1
    assert attempt.response_artifact_key

    assert {:ok, compressed} = Storage.get(attempt.response_artifact_key)
    assert Jason.decode!(:zstd.decompress(compressed))["model"] == "alibaba/qwen3.7-flash"

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert extracted.status == "extracted"
    assert [invoice] = extracted.invoices
    assert invoice["invoice_number"] == "DPS-0072"
    assert invoice["pages"] == [1]
  end

  test "the vision default persists segmentation and extraction as separate attempts" do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, Nila.Gst.Extraction.Purchase.Extractor)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      response =
        case get_in(request, ["response_format", "json_schema", "name"]) do
          "nila_packet_page_labels" ->
            chat_response(%{
              "pages" => [
                %{
                  "page" => 1,
                  "label" => "start",
                  "invoice_no" => "DPS-0072",
                  "reason" => nil
                }
              ]
            })

          "nila_purchase_invoice" ->
            vision_invoice_response()
        end

      Req.Test.json(conn, response)
    end)

    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "orgs/#{org.id}/gst/test/vision.jpg"
    {:ok, _stored} = Storage.put(key, <<0xFF, 0xD8, 0xFF, 0xD9>>)

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [key]}
      )

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    attempts = ExtractionAttempts.list_for_dump(dump.id)
    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.status == "succeeded" and &1.response_artifact_key))

    assert attempts |> Enum.map(& &1.request_metadata["stage"]) |> Enum.sort() ==
             ["vision_extraction", "vision_segmentation"]

    extraction =
      Enum.find(attempts, &(&1.request_metadata["stage"] == "vision_extraction"))

    assert [%{"pages" => [1], "status" => 200}] = extraction.request_metadata["responses"]

    assert {:ok, compressed} = Storage.get(extraction.response_artifact_key)
    assert %{"responses" => [%{"pages" => [1]}]} = Jason.decode!(:zstd.decompress(compressed))

    {:ok, extracted} = Dumps.fetch(org.id, dump.id)
    assert [%{"invoice_number" => "DPS-0072", "images" => [image]}] = extracted.invoices
    assert image == "d#{dump.id}_page_01.jpg"
    refute extracted.meta["evidence_unavailable"]

    assert {:ok, <<0xFF, 0xD8, 0xFF, 0xD9>>} =
             PurchaseMonths.fetch_evidence(org.id, client.id, "2025-10", image)
  end

  defmodule UnrenderableProvider do
    @behaviour Nila.Gst.Extraction.Purchase

    def provider, do: "vercel-ai-gateway"
    def model, do: "alibaba/qwen3.7-flash"

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

  defp vision_invoice_response do
    chat_response(%{
      "document_type" => "invoice",
      "invoice_number" => "DPS-0072",
      "invoice_date" => "08/10/2025",
      "seller" => %{
        "name" => "Dawn Power",
        "gstin" => "32AAMFD7558A1ZL",
        "address" => "Kerala"
      },
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "delivery_address" => nil,
      "line_items" => [],
      "printed_subtotal_before_discount" => nil,
      "printed_discount_amount" => nil,
      "printed_total_taxable" => 17_000,
      "printed_tax_totals" => [
        %{"printed_label" => "IGST", "printed_amount" => 3_060}
      ],
      "printed_additional_charges" => nil,
      "printed_rounding_adjustment" => nil,
      "printed_grand_total" => 20_060,
      "reverse_charge" => nil
    })
  end

  defp chat_response(content) do
    %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
      "usage" => %{"total_tokens" => 100}
    }
  end
end
