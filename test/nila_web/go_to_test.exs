defmodule NilaWeb.GoToTest do
  use ExUnit.Case, async: true
  alias NilaWeb.GoTo
  @client %{id: 42, name: "Caltech"}

  test "rendered destinations retain context and supply local search aliases" do
    entries = GoTo.destinations(@client, "/gst/42/2026-07/sales", nil)
    entry = Enum.find(entries, &(&1.id == "register"))
    assert entry.path == "/gst/42/2026-07/sales/invoices"
    assert entry.context == "Caltech · July 2026"
    assert entry.keywords == "sales bills invoices"

    upload =
      GoTo.destinations(@client, "/gst/upload?period=2025-12", nil)
      |> Enum.find(&(&1.id == "upload"))

    assert URI.decode_query(URI.parse(upload.path).query) == %{
             "client_id" => "42",
             "kind" => "sales",
             "period" => "2025-12"
           }
  end

  test "period links cover all months, with three suggestions across year boundaries" do
    periods =
      GoTo.destinations(@client, "/gst/42/2026-01/sales/invoices", nil)
      |> Enum.filter(& &1.period)

    assert length(periods) == 12

    assert Enum.map(Enum.filter(periods, & &1.suggested), & &1.period) == [
             "2026-02",
             "2026-01",
             "2025-12"
           ]

    assert Enum.all?(periods, &String.ends_with?(&1.path, "/sales/invoices"))
  end

  test "switching clients keeps month but leaves invoice-specific routes" do
    assert GoTo.client_path(
             "/gst/42/2026-07/sales/invoices?q=Buyer&filter=review_cases#invoice",
             nil,
             9
           ) ==
             "/gst/9/2026-07/sales/invoices?filter=review_cases"

    upload = GoTo.client_path("/gst/upload?client_id=42&period=2026-07&kind=sales", nil, 9)

    assert URI.decode_query(URI.parse(upload).query) == %{
             "client_id" => "9",
             "period" => "2026-07",
             "kind" => "sales"
           }

    assert GoTo.client_path("/gst/42/2026-07/sales/invoices/source-123", nil, 9) ==
             "/gst/9/2026-07/sales"

    assert GoTo.client_path(nil, "2026-07", 9) == "/gst/9/2026-07/sales"
  end
end
