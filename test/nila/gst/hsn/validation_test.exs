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
end
