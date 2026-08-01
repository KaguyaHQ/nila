defmodule Nila.Gst.Rates.ValidationTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Rates.{Release, Rule, Validation}

  @release %Release{
    id: 4,
    notification_number: "9/2025-Integrated Tax (Rate)",
    effective_from: ~D[2025-09-22]
  }

  test "flags 71069290 at 18% against the unconditional 3% candidate with a citation" do
    invoice = sales_invoice("71069290", 18, ~D[2025-10-08])
    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule()]))

    validation = get_in(annotated, ["line_items", Access.at(0), "rate_validation"])
    assert validation["status"] == "incompatible"
    assert validation["candidate_rates"] == [3.0]

    [issue] = Validation.sales_issues([annotated])
    assert issue["code"] == "statutory_rate_mismatch"
    assert issue["message"] =~ "printed HSN 71069290 at 18%"
    assert issue["message"] =~ "statutory candidate 3%"
    assert issue["message"] =~ "Schedule IV, entry 3"
    assert issue["message"] =~ "Confirm whether the HSN or rate needs correction"
  end

  test "accepts a printed rate found among the candidates" do
    invoice = sales_invoice("71069290", 3, ~D[2025-10-08])
    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule()]))

    assert get_in(annotated, ["line_items", Access.at(0), "rate_validation", "status"]) ==
             "compatible"

    assert Validation.sales_issues([annotated]) == []
  end

  test "routes conditional candidates to review rather than claiming incompatibility" do
    conditional = %{silver_rule() | parser_confidence: "review"}
    invoice = sales_invoice("71069290", 18, ~D[2025-10-08])
    [annotated] = Validation.annotate_invoices([invoice], directory([conditional]))

    assert get_in(annotated, ["line_items", Access.at(0), "rate_validation", "status"]) ==
             "review"

    assert [%{"code" => "statutory_rate_review"}] = Validation.sales_issues([annotated])
  end

  test "does not apply the release before its effective date" do
    invoice = sales_invoice("71069290", 18, ~D[2025-09-21])
    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule()]))

    assert get_in(annotated, ["line_items", Access.at(0), "rate_validation", "status"]) ==
             "before_effective_date"

    assert Validation.sales_issues([annotated]) == []
  end

  test "derives a purchase line's rate from tax amounts when printed rates are absent" do
    invoice = %{
      "id" => "purchase-1",
      "invoice_date" => ~D[2025-10-08],
      "line_items" => [
        %{
          "description" => "Silver rod",
          "hsn_sac" => "71069290",
          "hsn_kind" => "hsn",
          "taxable_paise" => 100_00,
          "tax_paise" => %{"cgst" => 9_00, "sgst" => 9_00, "igst" => 0}
        }
      ]
    }

    [annotated] = Validation.annotate_invoices([invoice], directory([silver_rule()]))
    [flag] = Validation.purchase_flags(annotated)
    assert flag["code"] == "statutory_rate_review"
    assert flag["reason"] =~ "at 18%"
  end

  test "does not pretend a description-only Any Chapter rule applies to every HSN" do
    any_chapter = %Rule{
      serial_number: 10,
      schedule: "II",
      total_rate: Decimal.new("18"),
      raw_code_expression: "Any Chapter",
      raw_description: "A specifically described product",
      parsed_scope: %{
        "includes" => [],
        "excludes" => [],
        "ranges" => [],
        "any_chapter" => true
      },
      parser_confidence: "review"
    }

    invoice = sales_invoice("71069290", 3, ~D[2025-10-08])
    [annotated] = Validation.annotate_invoices([invoice], directory([any_chapter]))

    assert get_in(annotated, ["line_items", Access.at(0), "rate_validation", "status"]) ==
             "no_rule"
  end

  defp directory(rules), do: %{release: @release, rules: rules}

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

  defp sales_invoice(code, rate, date) do
    %{
      "invoice_number" => "133/2025-26",
      "invoice_date" => date,
      "line_items" => [
        %{
          "description" => "Silver Rod 43%",
          "hsn_sac" => code,
          "hsn_kind" => "hsn",
          "cgst_rate" => rate / 2,
          "sgst_rate" => rate / 2,
          "igst_rate" => nil
        }
      ]
    }
  end
end
