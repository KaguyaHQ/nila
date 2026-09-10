defmodule Nila.Gst.ProposalsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Invoice.Validation, as: InvoiceValidation
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Proposals
  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Sales.Review.Values

  @seller "33AEWPH4158J1Z3"
  @period "2026-05"

  defp invoice(line_items, printed \\ %{}) do
    Normalizer.normalize(%{
      "data" =>
        Map.merge(
          %{
            "invoice_number" => "P-1",
            "invoice_date" => "04.05.2026",
            "seller" => %{"gstin" => @seller},
            "buyer" => %{"gstin" => "33AABCP9487A1ZG"},
            "line_items" => line_items
          },
          printed
        )
    })
    |> Map.put("id", "proposal-source-1")
  end

  defp clean_line(taxable) do
    side = Float.round(taxable * 18 / 200, 2)

    %{
      "printed_taxable_value" => taxable,
      "cgst_rate" => 9,
      "cgst_amount" => side,
      "sgst_rate" => 9,
      "sgst_amount" => side
    }
  end

  defp context(invoice) do
    projection = Gstr1.project([invoice], Gstr1.production_header(@seller, @period))
    {Values.for_invoice(invoice, projection), InvoiceValidation.checks(invoice)}
  end

  describe "arithmetic mismatches" do
    test "proposes accepting the lines, on a basis that is an observation" do
      invoice = invoice([clean_line(10_000.0)], %{"printed_grand_total" => 99_999.0})
      {values, checks} = context(invoice)

      issue = %{"code" => "grand_total_mismatch"}
      proposal = Proposals.for_issue(issue, values, checks)

      assert proposal.action == "Accept the extracted lines"
      assert proposal.basis =~ "Every line's arithmetic checks out"
      assert proposal.decision == "use_extracted_lines"

      # The effect names its meaning and stores what reaches the portal in paise.
      assert proposal.effect.schema_version == 1
      assert proposal.effect.kind == "filing_result"
      assert proposal.effect.amounts.tax_paise == round(values.filed.tax * 100)
      assert proposal.effect.amounts.taxable_paise == round(values.filed.taxable * 100)
      assert proposal.effect.amounts.cgst_paise == 90_000
    end

    test "no proposal when a line is also failing — the basis would be false" do
      # 10,000 at 18% is 1,800, not 1,000. "Only the footer disagrees" is not a
      # true statement about this bill, so Nila has nothing to recommend and the
      # reviewer is owed the question rather than a recommendation resting on a
      # false premise.
      broken = %{
        "printed_taxable_value" => 10_000.0,
        "cgst_rate" => 9,
        "cgst_amount" => 500.0,
        "sgst_rate" => 9,
        "sgst_amount" => 500.0
      }

      invoice = invoice([broken], %{"printed_grand_total" => 99_999.0})
      {values, checks} = context(invoice)

      refute Enum.all?(checks, & &1["passed"])
      refute Proposals.for_issue(%{"code" => "grand_total_mismatch"}, values, checks)
    end

    test "no proposal when the invoice is not in the return" do
      invoice = invoice([clean_line(10_000.0)], %{"printed_grand_total" => 99_999.0})
      {_values, checks} = context(invoice)

      absent = Values.for_invoice(invoice, nil)

      refute absent.filed
      refute Proposals.for_issue(%{"code" => "grand_total_mismatch"}, absent, checks)
    end
  end

  describe "the cases with no honest basis" do
    test "stay silent rather than guess" do
      invoice = invoice([clean_line(10_000.0)])
      {values, checks} = context(invoice)

      # Each would require Nila to assert something it did not observe: what was
      # cancelled, what an item legally is, or where a supply happened. No
      # proposal is better than a weak one.
      for code <- ~w(sequence_gaps hsn_inferred_code hsn_multiple_rates
                     statutory_rate_mismatch rate_history_conflict
                     mixed_tax_heads tax_split_mismatch duplicate_invoice_number
                     cess_unsupported line_arithmetic) do
        refute Proposals.for_issue(%{"code" => code}, values, checks),
               "#{code} must not carry a proposal"
      end
    end
  end

  describe "missing bills" do
    test "the treatment is a request, and the basis is what the portal reported" do
      proposal = Proposals.for_missing_bill(9, 61_200)

      assert proposal.action == "Request the 9 missing bills from the client"
      assert proposal.basis =~ "portal reported 9 supplies"
      assert proposal.effect.kind == "claim_exposure"
      assert proposal.effect.amounts.tax_paise == 61_200
      assert proposal.effect.amounts.taxable_paise == nil
    end

    test "one bill reads as one bill" do
      assert Proposals.for_missing_bill(1, 100).action ==
               "Request the 1 missing bill from the client"
    end

    test "nothing missing means nothing to propose" do
      refute Proposals.for_missing_bill(0, 0)
    end
  end

  describe "freeze/1" do
    test "captures what the reviewer was shown, with the rule version behind it" do
      invoice = invoice([clean_line(10_000.0)], %{"printed_grand_total" => 99_999.0})
      {values, checks} = context(invoice)

      frozen =
        %{"code" => "grand_total_mismatch"}
        |> Proposals.for_issue(values, checks)
        |> Proposals.freeze()

      # A rule change in October must not rewrite what August's audit screen
      # claims Nila advised, so the version it was generated under travels with
      # it.
      assert frozen["rule_version"]
      assert frozen["action"] == "Accept the extracted lines"
      assert frozen["decision"] == "use_extracted_lines"
      assert frozen["effect"]["schema_version"] == 1
      assert frozen["effect"]["kind"] == "filing_result"
      assert frozen["effect"]["amounts"]["tax_paise"] == 180_000
      assert %DateTime{} = frozen["shown_at"]
    end

    test "nothing shown, nothing frozen" do
      refute Proposals.freeze(nil)
    end
  end
end
