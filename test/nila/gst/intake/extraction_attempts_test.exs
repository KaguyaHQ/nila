defmodule Nila.Gst.Intake.ExtractionAttemptsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.{Dumps, ExtractionAttempts}
  alias Nila.Storage

  test "persists immutable provider attempts and a compressed private raw response" do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    source_key = "orgs/#{org.id}/gst/test/source.pdf"

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "purchase", file_keys: [source_key]}
      )

    started_at = DateTime.utc_now()

    assert {:ok, running} =
             ExtractionAttempts.start(dump, %{
               source_storage_key: source_key,
               provider: "vercel-ai-gateway",
               model: "alibaba/qwen3.7-flash",
               worker_attempt: 1,
               source_byte_size: 12_345,
               started_at: started_at
             })

    assert running.status == "running"

    raw = Jason.encode!(%{"pages" => [%{"index" => 0}], "usage_info" => %{"pages" => 1}})

    assert {:ok, completed} =
             ExtractionAttempts.succeed(running, %{
               provider_request_id: "req-123",
               http_status: 200,
               source_page_count: 1,
               duration_ms: 321,
               usage: %{"pages" => 1},
               raw_response: raw
             })

    assert completed.status == "succeeded"
    assert completed.provider == "vercel-ai-gateway"
    assert completed.model == "alibaba/qwen3.7-flash"
    assert completed.source_byte_size == 12_345
    assert completed.response_byte_size == byte_size(raw)
    assert completed.response_sha256 == sha256(raw)
    assert completed.response_artifact_key
    assert completed.artifact_byte_size > 0

    assert {:ok, compressed} = Storage.get(completed.response_artifact_key)
    assert IO.iodata_to_binary(:zstd.decompress(compressed)) == raw

    assert [listed] = ExtractionAttempts.list_for_dump(dump.id)
    assert listed.id == completed.id
  end

  test "records failed calls separately instead of overwriting prior attempts" do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Client", type: "company"})

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "sales", file_keys: ["source.pdf"]}
      )

    for worker_attempt <- 1..2 do
      {:ok, attempt} =
        ExtractionAttempts.start(dump, %{
          source_storage_key: "source.pdf",
          provider: "vercel-ai-gateway",
          model: "alibaba/qwen3.7-flash",
          worker_attempt: worker_attempt,
          source_byte_size: 10,
          started_at: DateTime.utc_now()
        })

      assert {:ok, failed} =
               ExtractionAttempts.fail(attempt, %{
                 duration_ms: worker_attempt,
                 error: "timeout"
               })

      assert failed.status == "failed"
    end

    assert Enum.map(ExtractionAttempts.list_for_dump(dump.id), & &1.worker_attempt) == [1, 2]
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
