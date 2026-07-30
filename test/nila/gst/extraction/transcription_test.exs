defmodule Nila.Gst.Extraction.TranscriptionTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Transcription

  defp response(pages), do: Jason.encode!(%{"pages" => pages})

  test "splices externalized tables back into the page they were lifted out of" do
    body =
      response([
        %{
          "index" => 0,
          "markdown" => "TAX INVOICE\n\n[tbl-0.md](tbl-0.md)\n\nThank you",
          "tables" => [%{"id" => "tbl-0.md", "content" => "| Item | Qty |\n| Bolt | 4 |"}]
        }
      ])

    {:ok, transcription} = Transcription.from_response(body)
    text = Transcription.page_text(transcription, 1)

    # Without this, every regex, every grounding check and the model itself see a
    # page whose entire table is the string "[tbl-0.md](tbl-0.md)".
    assert text =~ "| Bolt | 4 |"
    refute text =~ "[tbl-0.md]"
    assert text =~ "Thank you"
  end

  test "appends a table whose link the markdown never contained" do
    body =
      response([
        %{
          "index" => 0,
          "markdown" => "TAX INVOICE",
          "tables" => [%{"id" => "tbl-9.md", "content" => "| Item |"}]
        }
      ])

    {:ok, transcription} = Transcription.from_response(body)
    assert Transcription.page_text(transcription, 1) =~ "| Item |"
  end

  test "numbers pages by the document-absolute index, not response position" do
    body =
      response([
        %{"index" => 12, "markdown" => "thirteen"},
        %{"index" => 13, "markdown" => "fourteen"}
      ])

    {:ok, transcription} = Transcription.from_response(body)

    assert Transcription.numbers(transcription) == [13, 14]
    assert Transcription.page_text(transcription, 13) == "thirteen"
  end

  test "merging batches records a page whose two reads disagree rather than picking one" do
    {:ok, first} =
      Transcription.from_response(response([%{"index" => 0, "markdown" => "TAX INVOICE"}]))

    {:ok, second} =
      Transcription.from_response(response([%{"index" => 0, "markdown" => "DELIVERY CHALLAN"}]))

    merged = Transcription.merge([first, second])

    assert merged.disagreements == [1]
    assert Transcription.page_text(merged, 1) == "TAX INVOICE"
  end

  test "merging identical reads of the same page is not a disagreement" do
    {:ok, one} = Transcription.from_response(response([%{"index" => 0, "markdown" => "same"}]))
    {:ok, two} = Transcription.from_response(response([%{"index" => 0, "markdown" => "same"}]))

    assert Transcription.merge([one, two]).disagreements == []
  end

  test "text/2 marks each page so a value can be traced back to a scan" do
    body = response([%{"index" => 0, "markdown" => "one"}, %{"index" => 1, "markdown" => "two"}])
    {:ok, transcription} = Transcription.from_response(body)

    assert Transcription.text(transcription, [2, 1]) ==
             "--- page 1 ---\none\n\n--- page 2 ---\ntwo"
  end
end
