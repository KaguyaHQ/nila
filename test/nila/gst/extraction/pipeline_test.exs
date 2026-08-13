defmodule Nila.Gst.Extraction.PipelineTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Pipeline
  alias Nila.Gst.Extraction.Providers.Mistral
  alias Nila.Gst.Extraction.Providers.MistralChat
  alias Nila.PdfFixtures

  defp ocr_response(pages) do
    %{
      "model" => "mistral-ocr-4-0",
      "pages" =>
        Enum.map(pages, fn {number, markdown} ->
          %{"index" => number - 1, "markdown" => markdown}
        end),
      "usage_info" => %{"pages_processed" => length(pages)}
    }
  end

  defp chat_response(content) do
    %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
      "usage" => %{"total_tokens" => 40}
    }
  end

  defp bill(number) do
    """
    TAX INVOICE No. #{number}
    GSTIN 32AAMFD7558A1ZL
    | Bolt | 4 | 1,000.00 |
    Taxable 1,000.00  CGST 90.00  SGST 90.00
    Grand total 1,180.00
    """
  end

  defp stub_chat(label_fun, invoice_fun) do
    Req.Test.stub(MistralChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      case get_in(request, ["response_format", "json_schema", "name"]) do
        "nila_page_label" -> label_fun.(conn, request)
        _invoice -> invoice_fun.(conn, request)
      end
    end)
  end

  defp label(conn, request, opts \\ []) do
    [_system, user] = request["messages"]
    [page] = Regex.run(~r/JUDGE THIS PAGE — page (\d+)/, user["content"], capture: :all_but_first)

    Req.Test.json(
      conn,
      chat_response(%{
        "label" => Keyword.get(opts, :label, "start"),
        "invoice_no" => "INV-#{page}",
        "reason" => nil
      })
    )
  end

  defp invoice(conn, _request) do
    Req.Test.json(
      conn,
      chat_response(%{
        "invoice_number" => "INV-1",
        "line_items" => [%{"taxable_value" => 1_000.0}],
        "printed_total_taxable" => 1_000.0,
        "printed_grand_total" => 1_180.0
      })
    )
  end

  @tag :capture_log
  test "a transcription that times out is asked again before the dump is failed" do
    # Mistral caches OCR on identical bytes, so the resend lands in seconds. The
    # former reader relied on this; dropping the retry during the cutover
    # would have turned one slow response into a failed month.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Mistral, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> Req.Test.transport_error(conn, :timeout)
        _retry -> Req.Test.json(conn, ocr_response([{1, bill("INV-1")}]))
      end
    end)

    stub_chat(&label/2, &invoice/2)

    test_pid = self()

    assert {:ok, %{pages: [artifact]}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(1),
               filename: "packet.pdf",
               on_progress: &send(test_pid, &1)
             )

    assert_receive {:retrying, "all"}
    assert artifact["data"]["invoice_number"] == "INV-1"
    assert Agent.get(counter, & &1) == 2
  end

  @tag :capture_log
  test "a transport failure with no per-call wrapper returns an error, never a raised case" do
    Req.Test.stub(Mistral, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, {:mistral_ocr_request_failed, _reason}} =
             Pipeline.extract(:purchase, "%PDF-1.7", filename: "packet.pdf")
  end

  test "a read that produced no invoice at all fails rather than deriving an empty month" do
    # Provider failure is infrastructure state, so no subset can leave the stage
    # and overwrite whatever the month already held.
    Req.Test.stub(Mistral, fn conn ->
      Req.Test.json(conn, ocr_response([{1, bill("INV-1")}]))
    end)

    stub_chat(&label/2, fn conn, _request ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "schema rejected"})
    end)

    assert {:error, {:invoice_segments_failed, [failure]}} =
             Pipeline.extract(:purchase, "%PDF-1.7", filename: "packet.pdf")

    assert failure.pages == [1]
  end

  test "one page whose label never comes back fails discovery instead of becoming unreadable" do
    Req.Test.stub(Mistral, fn conn ->
      Req.Test.json(conn, ocr_response([{1, bill("INV-1")}, {2, "a page"}]))
    end)

    stub_chat(
      fn conn, request ->
        [_system, user] = request["messages"]

        if user["content"] =~ "JUDGE THIS PAGE — page 2" do
          conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow down"})
        else
          label(conn, request)
        end
      end,
      &invoice/2
    )

    assert {:error,
            {:page_label_failed, 2, {:mistral_chat_failed, 429, %{"error" => "slow down"}}}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(2),
               filename: "packet.pdf",
               max_retries: 0
             )
  end

  test "reports segmented stages through on_progress" do
    Req.Test.stub(Mistral, fn conn ->
      Req.Test.json(conn, ocr_response([{1, bill("INV-1")}]))
    end)

    stub_chat(&label/2, &invoice/2)
    test_pid = self()

    assert {:ok, _result} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(1),
               filename: "packet.pdf",
               on_progress: &send(test_pid, &1)
             )

    assert_receive {:progress, %{stage: :transcribing, done: 0, total: 1}}
    assert_receive {:progress, %{stage: :segmenting, done: 0, total: 1}}
    assert_receive {:progress, %{stage: :segmenting, done: 1, total: 1}}
    assert_receive {:progress, %{stage: :reading, done: 0, total: 1}}
    assert_receive {:progress, %{stage: :reading, done: 1, total: 1}}
  end

  test "the audit carries what each stage learned, per stage" do
    Req.Test.stub(Mistral, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req-ocr")
      |> Req.Test.json(ocr_response([{1, bill("INV-1")}]))
    end)

    stub_chat(&label/2, &invoice/2)

    {:ok, calls} = Agent.start_link(fn -> [] end)

    per_call = fn metadata, call ->
      result = call.()
      Agent.update(calls, &(&1 ++ [{metadata, elem(result, 1)}]))
      result
    end

    assert {:ok, _result} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(1),
               filename: "packet.pdf",
               per_call: per_call
             )

    recorded = Agent.get(calls, & &1)

    assert Enum.map(recorded, fn {metadata, _result} -> metadata.stage end) ==
             ["transcription", "discovery", "extraction"]

    {_meta, transcription} = Enum.at(recorded, 0)
    assert transcription.audit.usage == %{"pages_processed" => 1}
    assert transcription.audit.provider_request_id == "req-ocr"

    {_meta, discovery} = Enum.at(recorded, 1)
    assert discovery.audit.usage == %{"total_tokens" => 40}
    assert discovery.audit.metadata["segments"] == 1

    {_meta, extraction} = Enum.at(recorded, 2)

    assert extraction.audit.metadata["segments"] == [
             %{"pages" => [1], "kind" => "invoice", "invoice_no" => "INV-1"}
           ]
  end
end
