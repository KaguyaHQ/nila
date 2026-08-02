defmodule Nila.Gst.Filing.PortalDocumentTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.PortalDocument

  test "identifies both supported GSTR-2B wrappers" do
    assert {:ok, "gstr2b"} = PortalDocument.classify(%{"docdata" => %{"b2b" => []}})

    assert {:ok, "gstr2b"} =
             PortalDocument.classify(%{"data" => %{"docdata" => %{"b2b" => []}}})
  end

  test "identifies a filed GSTR-1 by its filing period and return sections" do
    document = %{"gstin" => "33AAACS1234A1Z9", "fp" => "102025", "b2b" => []}

    assert {:ok, "filed_gstr1"} = PortalDocument.classify(document)
    assert {:ok, ^document} = PortalDocument.parse_filed_gstr1(document)
  end

  test "a top-level GSTIN alone is not enough to classify another portal return as GSTR-1" do
    assert {:error, :unrecognized_structure} =
             PortalDocument.classify(%{"gstin" => "33AAACS1234A1Z9", "fp" => "102025"})
  end

  test "refuses invalid, unknown, and ambiguous JSON" do
    assert {:error, :invalid_json} = PortalDocument.classify("{nope")
    assert {:error, :unrecognized_structure} = PortalDocument.classify(%{"other" => true})

    assert {:error, :ambiguous_structure} =
             PortalDocument.classify(%{
               "gstin" => "33AAACS1234A1Z9",
               "fp" => "102025",
               "b2b" => [],
               "docdata" => %{}
             })
  end

  test "filed GSTR-1 parsing preserves worker error semantics" do
    assert {:error, :invalid_json} = PortalDocument.parse_filed_gstr1("{nope")

    assert {:error, :not_a_filed_gstr1} =
             PortalDocument.parse_filed_gstr1(%{"data" => %{"docdata" => %{}}})
  end
end
