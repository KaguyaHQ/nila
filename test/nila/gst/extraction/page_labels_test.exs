defmodule Nila.Gst.Extraction.Discovery.PageLabelsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Discovery.PageLabels
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.Transcription

  defp label(page, label, invoice_no \\ nil) do
    %{page: page, label: label, invoice_no: invoice_no, reason: nil}
  end

  defp transcription(pages) do
    body =
      Jason.encode!(%{
        "pages" =>
          Enum.map(pages, fn {number, markdown} ->
            %{"index" => number - 1, "markdown" => markdown}
          end)
      })

    {:ok, transcription} = Transcription.from_response(body)
    transcription
  end

  describe "stitch/1" do
    test "a continuation chain becomes one segment, link by link" do
      segments =
        PageLabels.stitch([
          label(1, :start, "INV-1"),
          label(2, :continuation),
          label(3, :continuation),
          label(4, :start, "INV-2")
        ])

      assert Enum.map(segments, & &1.pages) == [[1, 2, 3], [4]]
      assert Enum.map(segments, & &1.invoice_no) == ["INV-1", "INV-2"]
    end

    test "a non-invoice closes the run rather than absorbing the next page" do
      segments =
        PageLabels.stitch([
          label(1, :start, "INV-1"),
          label(2, :non_invoice),
          label(3, :continuation)
        ])

      assert Enum.map(segments, &{&1.pages, &1.kind}) ==
               [{[1], :invoice}, {[2], :non_invoice}, {[3], :invoice}]
    end

    test "a continuation with nothing open becomes a start and says so" do
      # The alternative is a page belonging to no segment, which is the silence
      # this pipeline exists to remove.
      [segment] = PageLabels.stitch([label(1, :continuation)])

      assert segment.pages == [1]
      assert segment.kind == :invoice
      assert {:continuation_without_start, 1} in segment.issues
    end

    test "every page lands in exactly one segment, whatever the labels say" do
      labels =
        Enum.map(1..9, fn page ->
          label(page, Enum.at([:start, :continuation, :non_invoice, :unreadable], rem(page, 4)))
        end)

      pages = PageLabels.stitch(labels) |> Enum.flat_map(& &1.pages) |> Enum.sort()

      assert pages == Enum.to_list(1..9)
    end
  end

  describe "map_responses/1" do
    test "provider failure remains infrastructure state" do
      assert {:error, {:page_label_failed, 4, :rate_limited}} =
               PageLabels.map_responses([%{page: 4, error: :rate_limited}])
    end

    test "a successful unreadable verdict remains document semantics" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  Jason.encode!(%{
                    "label" => "unreadable",
                    "invoice_no" => nil,
                    "reason" => "garbled"
                  })
              }
            }
          ]
        })

      assert {:ok, [labelled]} =
               PageLabels.map_responses([%{page: 4, response: %{status: 200, body: body}}])

      assert labelled.label == :unreadable
      assert labelled.reason == "garbled"
    end
  end

  describe "request_page/3" do
    test "shows the judged page in full with its neighbours for context only" do
      t = transcription(Map.new(1..6, fn n -> {n, "page #{n} body"} end))

      Req.Test.expect(OpenAICompatibleChat, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [_system, user] = Jason.decode!(body)["messages"]

        assert user["content"] =~ "JUDGE THIS PAGE — page 3"
        assert user["content"] =~ "context — page 2"
        assert user["content"] =~ "context — page 4"
        refute user["content"] =~ "page 1 body"
        refute user["content"] =~ "page 5 body"
        # Context is bounded, so a 57-page packet costs no more per decision
        # than a 3-page one.
        refute user["content"] =~ "page 6 body"

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  Jason.encode!(%{"label" => "start", "invoice_no" => "A-1", "reason" => nil})
              }
            }
          ]
        })
      end)

      {:ok, response} = PageLabels.request_page(t, 3)
      {:ok, [labelled]} = PageLabels.map_responses([%{page: 3, response: response}])

      assert labelled.label == :start
      assert labelled.invoice_no == "A-1"
    end
  end
end
