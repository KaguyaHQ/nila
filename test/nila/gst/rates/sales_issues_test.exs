defmodule Nila.Gst.Rates.SalesIssuesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The per-invoice collapse of statutory rate findings.

  The generic `Sales.Workings.collapse_by_target/1` merges rows sharing a
  resolution target by keeping the first row's map and unioning message, fields
  and lines. Candidate rates are per code, so that merge printed line 1's
  statutory candidate against a message naming several lines — a citation
  against the wrong entry. These issues are therefore merged where they are
  raised.
  """

  alias Nila.Gst.Rates.{Release, Rule, Validation}

  @release %Release{
    id: 4,
    notification_number: "9/2025-Integrated Tax (Rate)",
    effective_from: ~D[2025-09-22]
  }

  test "flagged lines on one bill are one issue whose candidates match the lines it names" do
    invoice = %{
      "id" => "inv_01",
      "invoice_number" => "133/2025-26",
      "invoice_date" => ~D[2025-10-08],
      "line_items" => [
        line("Silver Rod 43%", "71069290", 18),
        line("Silver Rod 43%", "71069290", 3),
        line("Room air conditioner", "84151010", 5)
      ]
    }

    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule(), ac_rule()]))

    assert [issue] = Validation.sales_issues([annotated])

    assert issue["code"] == "statutory_rate_mismatch"
    assert issue["source_id"] == "inv_01"
    assert issue["lines"] == [1, 3]

    # Every code the issue speaks for, and every candidate rate belonging to
    # them — not the first line's alone.
    assert issue["hsn_codes"] == ["71069290", "84151010"]
    assert issue["hsn_code"] == "71069290"
    assert issue["hsn_rates"] == [3.0, 12.0]

    # Each line keeps its own finding, naming its own code, printed rate and
    # notification entry.
    assert issue["message"] =~ "Line 1 \"Silver Rod 43%\": printed HSN 71069290 at 18%"
    assert issue["message"] =~ "statutory candidate 3%"
    assert issue["message"] =~ "Schedule IV, entry 3"
    assert issue["message"] =~ "Line 3 \"Room air conditioner\": printed HSN 84151010 at 5%"
    assert issue["message"] =~ "statutory candidate 12%"
    assert issue["message"] =~ "Schedule II, entry 41"

    # Said once, about all of them.
    assert length(String.split(issue["message"], "Confirm whether the HSN or rate")) == 2

    # Every flagged value stays correctable.
    assert "line_items[0].hsn_sac" in issue["fields"]
    assert "line_items[2].hsn_sac" in issue["fields"]
    refute "line_items[1].hsn_sac" in issue["fields"]
  end

  test "an incompatible and a reviewable line stay separate issues" do
    invoice = %{
      "id" => "inv_01",
      "invoice_number" => "133/2025-26",
      "invoice_date" => ~D[2025-10-08],
      "line_items" => [
        line("Silver Rod 43%", "71069290", 18),
        line("Room air conditioner", "84151010", 5)
      ]
    }

    conditional = %{ac_rule() | parser_confidence: "review"}
    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule(), conditional]))

    assert [mismatch, review] = Validation.sales_issues([annotated])

    assert mismatch["code"] == "statutory_rate_mismatch"
    assert mismatch["lines"] == [1]
    assert mismatch["hsn_rates"] == [3.0]

    assert review["code"] == "statutory_rate_review"
    assert review["lines"] == [2]
    assert review["hsn_rates"] == [12.0]
    assert review["message"] =~ "may not match"
  end

  test "one flagged line reads exactly as it always did" do
    invoice = %{
      "id" => "inv_01",
      "invoice_number" => "133/2025-26",
      "invoice_date" => ~D[2025-10-08],
      "line_items" => [line("Silver Rod 43%", "71069290", 18)]
    }

    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule()]))
    [issue] = Validation.sales_issues([annotated])

    assert issue["message"] ==
             "Line 1 \"Silver Rod 43%\": printed HSN 71069290 at 18% does not match " <>
               "the statutory candidate 3%. Based on 9/2025-Integrated Tax (Rate), " <>
               "Schedule IV, entry 3, effective 2025-09-22. Confirm whether the HSN or " <>
               "rate needs correction; exemptions and description-dependent conditions " <>
               "are not automatically resolved."
  end

  defp directory(rules), do: %{release: @release, rules: rules}

  defp line(description, code, rate) do
    %{
      "description" => description,
      "hsn_sac" => code,
      "hsn_kind" => "hsn",
      "cgst_rate" => rate / 2,
      "sgst_rate" => rate / 2,
      "igst_rate" => nil
    }
  end

  defp silver_rule do
    %Rule{
      serial_number: 3,
      schedule: "IV",
      total_rate: Decimal.new("3"),
      raw_code_expression: "7106",
      raw_description: "Silver in semi-manufactured forms",
      parsed_scope: %{
        "includes" => ["7106"],
        "excludes" => [],
        "ranges" => [],
        "any_chapter" => false
      },
      parser_confidence: "automatic"
    }
  end

  defp ac_rule do
    %Rule{
      serial_number: 41,
      schedule: "II",
      total_rate: Decimal.new("12"),
      raw_code_expression: "8415",
      raw_description: "Air conditioning machines",
      parsed_scope: %{
        "includes" => ["8415"],
        "excludes" => [],
        "ranges" => [],
        "any_chapter" => false
      },
      parser_confidence: "automatic"
    }
  end
end
