defmodule Nila.Gst.Hsn.ValidationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Hsn.{Directory, Entry, Release, Validation}

  @directory %{
    release: %Release{id: 7},
    entries: %{
      "7106" => %Entry{code: "7106", kind: "hsn", digits: 4, description: "Silver"},
      "710692" => %Entry{
        code: "710692",
        kind: "hsn",
        digits: 6,
        description: "Semi-manufactured silver"
      },
      "71069290" => %Entry{
        code: "71069290",
        kind: "hsn",
        digits: 8,
        description: "Other"
      },
      "998719" => %Entry{
        code: "998719",
        kind: "sac",
        digits: 6,
        description: "Maintenance services"
      }
    },
    prefixes: MapSet.new(~w(7 71 710 7106 71069 710692 7106929 9 99 998 9987 99871))
  }

  test "validates exact rows rather than leaves or arbitrary prefixes" do
    assert %{status: "valid", description: "Silver"} = Directory.validate("7106", @directory)
    assert %{status: "valid"} = Directory.validate("710692", @directory)
    assert %{status: "incomplete"} = Directory.validate("71069", @directory)
    assert %{status: "invalid"} = Directory.validate("71069999", @directory)
  end

  test "annotates valid lines with the official description and release" do
    [invoice] =
      Validation.annotate_invoices(
        [%{"line_items" => [%{"description" => "Silver Rod 43%", "hsn_sac" => "71069290"}]}],
        @directory
      )

    [line] = invoice["line_items"]
    assert line["hsn_description"] == "Other"
    assert line["hsn_kind"] == "hsn"

    assert line["hsn_validation"] == %{
             "code" => "71069290",
             "description" => "Other",
             "digits" => 8,
             "kind" => "hsn",
             "release_id" => 7,
             "status" => "valid"
           }
  end

  test "creates distinct missing, incomplete and invalid sales issues" do
    invoices = [
      %{
        "invoice_number" => "135/2025-26",
        "line_items" => [
          %{"description" => "Missing", "hsn_sac" => nil},
          %{"description" => "Prefix", "hsn_sac" => "71069"},
          %{"description" => "Bogus", "hsn_sac" => "999999"}
        ]
      }
    ]

    issues =
      invoices
      |> Validation.annotate_invoices(@directory)
      |> Validation.sales_issues()

    assert Enum.map(issues, & &1["code"]) ==
             ~w(missing_hsn_sac incomplete_hsn_sac invalid_hsn_sac)
  end

  test "lines sharing one bad code are one issue, and still name every line" do
    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "135/2025-26",
        "line_items" => [
          %{"description" => "Bogus", "hsn_sac" => "999999"},
          %{"description" => "Silver Rod", "hsn_sac" => "71069290"},
          %{"description" => "Also bogus", "hsn_sac" => "999999"},
          %{"description" => "Third", "hsn_sac" => "888888"}
        ]
      }
    ]

    assert [issue] =
             invoices
             |> Validation.annotate_invoices(@directory)
             |> Validation.sales_issues()

    assert issue["code"] == "invalid_hsn_sac"
    assert issue["lines"] == [1, 3, 4]
    assert issue["message"] =~ "Lines 1, 3, 4"
    assert issue["message"] =~ "999999, 888888"

    # Every flagged line stays correctable: `flagged_fields/2` reads these.
    assert issue["fields"] == [
             "line_items[0].hsn_sac",
             "line_items[2].hsn_sac",
             "line_items[3].hsn_sac"
           ]

    # And every code stays reviewable. The collapse merged two bad codes into
    # one row; carrying only the first would let the row be answered with the
    # second code's lines never rendered.
    assert issue["hsn_codes"] == ["999999", "888888"]
    assert issue["hsn_code"] == "999999"
  end

  test "an all-missing issue carries no codes, because there are none to review" do
    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "135/2025-26",
        "line_items" => [
          %{"description" => "Nameless", "hsn_sac" => nil},
          %{"description" => "Also nameless", "hsn_sac" => nil}
        ]
      }
    ]

    assert [issue] =
             invoices
             |> Validation.annotate_invoices(@directory)
             |> Validation.sales_issues()

    assert issue["code"] == "missing_hsn_sac"
    assert issue["hsn_code"] == nil
    assert issue["hsn_codes"] == []
  end

  test "missing codes are knowable without an HSN directory" do
    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "135/2025-26",
        "line_items" => [%{"description" => "Service", "hsn_sac" => "  "}]
      }
    ]

    assert [%{"code" => "missing_hsn_sac", "lines" => [1]}] =
             Validation.sales_issues(invoices)
  end

  test "an inferred code requires confirmation" do
    invoices = [
      %{
        "id" => "inv_01",
        "invoice_number" => "135/2025-26",
        "line_items" => [
          %{
            "description" => "Silver Rod",
            "hsn_sac" => "710692",
            "hsn_inferred" => true,
            "taxable_value" => 1000,
            "cgst_rate" => 9,
            "sgst_rate" => 9
          }
        ]
      }
    ]

    issues =
      invoices
      |> Validation.annotate_invoices(@directory)
      |> Validation.summary_issues()

    assert [issue] = issues
    assert issue["code"] == "hsn_inferred_code"
    assert issue["message"] =~ "was inferred rather than read from the source document"
  end
end
