defmodule Nila.Gst.Sales.ReturnSuggestionsTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Sales.ReturnSuggestions

  defp annotate(rows), do: ReturnSuggestions.annotate(%{"rows" => rows})["rows"]
  defp hsn(values), do: %{"section" => "hsn_b2b", "values" => values}

  test "suggests the rate from supplied tax amounts without filling the source blank" do
    values = %{"rate" => nil, "txval" => 200, "iamt" => 0, "camt" => 18, "samt" => 18}
    [row] = annotate([hsn(values)])
    assert row["suggestion"]["values"] == %{"rate" => 18.0}
    assert row["values"] == values
  end

  test "does not suggest a rate for missing or conflicting tax amounts or overwrite one" do
    base = %{"rate" => nil, "txval" => 200, "iamt" => 0, "camt" => 18, "samt" => 18}

    for changes <- [
          %{"samt" => nil},
          %{"samt" => 9},
          %{"iamt" => 36},
          %{"txval" => 0},
          %{"rate" => 5}
        ] do
      assert [%{"suggestion" => nil}] = annotate([hsn(Map.merge(base, changes))])
    end
  end

  test "an unknown single-document label is suggested from a matching sales entry" do
    doc = %{
      "section" => "doc_issue",
      "values" => %{
        "nature" => "ERP custom name",
        "doc_num" => nil,
        "from" => "S1",
        "to" => "S1",
        "totnum" => 1.0,
        "cancel" => 0.0,
        "net_issue" => 1.0
      }
    }

    sale = %{
      "section" => "b2b",
      "values" => %{"number" => "S1", "date" => "2026-08-01", "buyer_gstin" => "buyer"}
    }

    [annotated, _] = annotate([doc, sale])
    assert annotated["suggestion"]["values"] == %{"doc_num" => 1}
    assert annotated["values"]["doc_num"] == nil
    assert [%{"suggestion" => nil}] = annotate([doc])
    assert [%{"suggestion" => nil}, _] = annotate([doc, %{sale | "section" => "cdnr"}])
  end
end
