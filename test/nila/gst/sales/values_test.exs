defmodule Nila.Gst.Sales.ValuesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.{Gstr1, Values}

  @seller "29AAAAA0000A1Z5"
  @period "2026-08"

  defp derive(invoices), do: Gstr1.derive(invoices, Gstr1.production_header(@seller, @period))

  defp invoice(attrs) do
    Map.merge(
      %{
        "invoice_number" => "T-1",
        "invoice_date" => "01-08-2026",
        "seller_gstin" => @seller,
        "buyer_gstin" => "29BBBBB0000B1Z5",
        "line_items" => []
      },
      attrs
    )
  end

  defp line(taxable, rate, mode) do
    case mode do
      :intrastate ->
        side = Float.round(taxable * rate / 200, 2)

        %{
          "taxable_value" => taxable,
          "cgst_rate" => rate / 2,
          "cgst_amount" => side,
          "sgst_rate" => rate / 2,
          "sgst_amount" => side,
          "igst_rate" => 0.0,
          "igst_amount" => 0.0
        }

      :interstate ->
        %{
          "taxable_value" => taxable,
          "cgst_rate" => 0.0,
          "cgst_amount" => 0.0,
          "sgst_rate" => 0.0,
          "sgst_amount" => 0.0,
          "igst_rate" => rate,
          "igst_amount" => Float.round(taxable * rate / 100, 2)
        }
    end
  end

  describe "the invariant" do
    test "filed is what derive/2 put in the return, for every invoice in it" do
      invoices = [
        invoice(%{
          "invoice_number" => "A-1",
          "line_items" => [line(1000.0, 18.0, :intrastate), line(2500.55, 18.0, :intrastate)]
        }),
        invoice(%{
          "invoice_number" => "A-2",
          "buyer_gstin" => "27CCCCC0000C1Z5",
          "line_items" => [line(999.99, 12.0, :interstate)]
        })
      ]

      derived = derive(invoices)

      # Read straight out of the return, so this cannot drift from the JSON the
      # portal receives.
      details =
        for group <- derived["b2b"],
            inv <- group["inv"],
            itm <- inv["itms"],
            do: itm["itm_det"]

      filed_tax =
        details |> Enum.map(&(&1["camt"] + &1["samt"] + &1["iamt"])) |> Enum.sum() |> round2()

      assert round2(Values.filed_totals(derived).tax) == filed_tax

      per_invoice =
        invoices |> Enum.map(&Values.filed(&1, derived).tax) |> Enum.sum() |> round2()

      assert per_invoice == filed_tax
    end

    test "credit-note face values stay positive while month liability is reduced" do
      sale =
        invoice(%{
          "invoice_number" => "I-1",
          "line_items" => [line(2000.0, 18.0, :intrastate)]
        })

      note =
        invoice(%{
          "document_type" => "credit_note",
          "invoice_number" => "CN-1",
          "line_items" => [line(500.0, 18.0, :intrastate)]
        })

      derived = derive([sale, note])
      note_values = Values.for_invoice(note, derived)

      assert note_values.filed.taxable == 500.0
      assert note_values.filed.tax == 90.0
      assert note_values.liability_effect.taxable == -500.0
      assert note_values.liability_effect.tax == -90.0
      assert Values.filed_totals(derived).taxable == 1500.0
      assert Values.filed_totals(derived).tax == 270.0
    end

    test "debit-note face values and liability effect both stay positive" do
      sale =
        invoice(%{
          "invoice_number" => "INV-1",
          "line_items" => [line(100_000.0, 18.0, :intrastate)]
        })

      note =
        invoice(%{
          "document_type" => "debit_note",
          "invoice_number" => "DN-1",
          "line_items" => [line(10_000.0, 18.0, :intrastate)]
        })

      derived = derive([sale, note])
      note_values = Values.for_invoice(note, derived)

      assert note_values.filed.taxable == 10_000.0
      assert note_values.filed.tax == 1_800.0
      assert note_values.liability_effect.taxable == 10_000.0
      assert note_values.liability_effect.tax == 1_800.0
      assert Values.filed_totals(derived).taxable == 110_000.0
      assert Values.filed_totals(derived).tax == 19_800.0
    end

    test "credit and debit notes sharing a number resolve by note type" do
      credit =
        invoice(%{
          "document_type" => "credit_note",
          "invoice_number" => "N-1",
          "line_items" => [line(500.0, 18.0, :intrastate)]
        })

      debit =
        invoice(%{
          "document_type" => "debit_note",
          "invoice_number" => "N-1",
          "line_items" => [line(700.0, 18.0, :intrastate)]
        })

      derived = derive([credit, debit])

      assert Values.filed(credit, derived).taxable == 500.0
      assert Values.filed(debit, derived).taxable == 700.0
      assert Values.for_invoice(credit, derived).liability_effect.taxable == -500.0
      assert Values.for_invoice(debit, derived).liability_effect.taxable == 700.0
    end

    test "the filed total is computed once — the month equals the sum of its invoices" do
      invoices =
        for n <- 1..7 do
          invoice(%{
            "invoice_number" => "M-#{n}",
            "line_items" => [line(1000.0 + n * 33.33, 18.0, :intrastate)]
          })
        end

      derived = derive(invoices)
      month = Values.filed_totals(derived)
      summed = invoices |> Enum.map(&Values.filed(&1, derived)) |> Enum.reduce(&add/2)

      for field <- [:taxable, :igst, :cgst, :sgst, :tax] do
        assert round2(Map.fetch!(month, field)) == round2(Map.fetch!(summed, field))
      end
    end
  end

  describe "extracted lines versus what is filed" do
    test "per-bucket rounding makes the filed tax differ from the raw line sum" do
      # Each line's own half rounds down; the bucket halves the summed taxable
      # once and rounds that. The return therefore files two paise MORE than the
      # extracted lines add up to — the difference is not signed one way, which
      # is why neither figure can stand in for the other.
      invoices = [
        invoice(%{
          "line_items" => [line(0.25, 18.0, :intrastate), line(0.5, 18.0, :intrastate)]
        })
      ]

      values = Values.for_invoice(hd(invoices), derive(invoices))

      assert values.extracted_lines.tax == 0.12
      assert values.filed.tax == 0.14

      # Paise-level, and it is what the `info` rounding issue reports. Not a
      # defect; it is why the two figures need two names.
      assert values.extracted_vs_filed.tax == 0.02
      refute values.head_reassignment
    end

    test "two invoices sharing a number have no single filed figure" do
      # `duplicate_invoice_number` is blocking, but the modal is open during
      # exactly the window when it is unresolved. Matching on the number alone
      # would sum both copies and show a reviewer double the tax while they
      # decide which copy is real.
      copies = [
        invoice(%{"invoice_number" => "D-1", "line_items" => [line(1000.0, 18.0, :intrastate)]}),
        invoice(%{"invoice_number" => "D-1", "line_items" => [line(1000.0, 18.0, :intrastate)]})
      ]

      derived = derive(copies)

      refute Values.filed(hd(copies), derived)
      refute Values.for_invoice(hd(copies), derived).extracted_vs_filed

      # The month total still counts both, because the return does.
      assert Values.filed_totals(derived).tax == 360.0
    end

    test "missing taxable remains unknown while independently extracted GST remains visible" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "taxable_value" => nil,
              "igst_rate" => 18,
              "igst_amount" => 1_800
            }
          ]
        })

      extracted = Values.extracted_lines(inv)

      assert extracted.taxable == nil
      assert extracted.tax == 1_800.0
      assert extracted.igst == 1_800.0
    end

    test "an invoice held out of the return files nothing rather than zero" do
      invoices = [invoice(%{"line_items" => [line(1000.0, 18.0, :intrastate)]})]
      derived = derive(invoices)

      absent = invoice(%{"invoice_number" => "NOT-IN-RETURN"})

      # Nil, not a zeroed map: "excluded" and "filed as ₹0" are different facts
      # and a surface must be able to tell them apart.
      refute Values.filed(absent, derived)
      refute Values.for_invoice(absent, derived).filed
      refute Values.for_invoice(absent, derived).extracted_vs_filed
    end
  end

  describe "tax-head fidelity" do
    test "the return preserves printed heads when an inferred place of supply disagrees" do
      # Both GSTINs are 29, but the source carries IGST. The GSTIN-derived place
      # of supply is only an operational default, so it must not rewrite tax.
      inv =
        invoice(%{
          "printed_total_tax" => 1800.0,
          "line_items" => [line(10_000.0, 18.0, :interstate)]
        })

      values = Values.for_invoice(inv, derive([inv]))

      assert values.extracted_lines.tax == 1800.0
      assert values.filed.tax == 1800.0
      assert values.extracted_vs_filed.tax == 0.0

      assert values.filed.igst == 1800.0
      assert values.filed.cgst == 0.0
      assert values.filed.sgst == 0.0
      refute values.head_reassignment

      # The total-level check passes, which is the whole point: nothing else on
      # the page can see this.
      assert Enum.all?(
               Enum.filter(Gstr1.invoice_checks(inv), &(&1["code"] == "printed_tax_mismatch")),
               & &1["passed"]
             )
    end

    test "the GSTIN pair raises uncertainty without deciding the heads" do
      inv =
        invoice(%{
          "printed_total_tax" => 1800.0,
          "line_items" => [line(10_000.0, 18.0, :interstate)]
        })

      filed = Values.for_invoice(inv, derive([inv])).filed

      assert filed.igst == 1800.0
      assert filed.cgst == 0.0
      assert filed.sgst == 0.0

      # And it is never a silent default: the disagreement gates the month, so
      # no return leaves on the inference without a reviewer seeing it.
      codes = Enum.map(Gstr1.validation_issues([inv]), & &1["code"])
      assert "tax_treatment_uncertain" in codes
    end

    test "agreeing heads report no reassignment" do
      inv = invoice(%{"line_items" => [line(10_000.0, 18.0, :intrastate)]})
      refute Values.for_invoice(inv, derive([inv])).head_reassignment
    end

    test "a paise of bucket rounding is not a reassignment" do
      # CGST and SGST differ from the extraction by rounding, but the supply is
      # intrastate in both readings — nothing was reassigned. Reporting this as
      # an inter/intra-state change would be a louder claim than the evidence
      # supports.
      inv =
        invoice(%{
          "line_items" => [line(0.25, 18.0, :intrastate), line(0.5, 18.0, :intrastate)]
        })

      values = Values.for_invoice(inv, derive([inv]))

      assert values.extracted_vs_filed.cgst == 0.01
      refute values.head_reassignment
    end
  end

  describe "effect/2" do
    test "states the change in the figures actually filed" do
      before_invoices = [
        invoice(%{"invoice_number" => "E-1", "line_items" => [line(1000.0, 18.0, :intrastate)]})
      ]

      after_invoices =
        before_invoices ++
          [
            invoice(%{
              "invoice_number" => "E-2",
              "line_items" => [line(500.0, 18.0, :intrastate)]
            })
          ]

      effect = Values.effect(derive(before_invoices), derive(after_invoices))

      assert effect.before.tax == 180.0
      assert effect.after.tax == 270.0
      assert effect.change.tax == 90.0
      assert effect.change.cgst == 45.0
      assert effect.change.sgst == 45.0
      assert effect.change.taxable == 500.0
    end
  end

  describe "printed/1" do
    test "a field the bill did not print is nil, not zero" do
      printed = Values.printed(invoice(%{"printed_total_tax" => 118.0}))

      assert printed.tax == 118.0
      refute printed.taxable
      refute printed.total
    end

    test "a field the bill never printed yields no difference, not a difference of its whole value" do
      # "The footer disagrees by ₹1,180" and "there is no footer" are different
      # findings. Only the first is a question for a reviewer.
      inv =
        invoice(%{
          "printed_total_tax" => 179.5,
          "line_items" => [line(1000.0, 18.0, :intrastate)]
        })

      diff = Values.for_invoice(inv, derive([inv])).printed_vs_extracted

      assert diff.tax == 0.5
      refute diff.taxable
      refute diff.total
    end
  end

  defp add(a, b) do
    Map.new(a, fn {k, v} -> {k, v + Map.fetch!(b, k)} end)
  end

  defp round2(v), do: Float.round(v / 1, 2)
end
