defmodule Nila.Gst.Filing.Gstr3bTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.{Gstr2b, Gstr3b, ItcPosition}
  alias Nila.Gst.Purchase.Reconciliation, as: Recon

  @fixtures Path.expand("../../../fixtures/purchase/breeze/2025-10", __DIR__)
  @december_fixture Path.expand(
                      "../../../fixtures/purchase/breeze/2025-12/returns_R2B_33AEWPH4158J1Z3_122025.json",
                      __DIR__
                    )

  describe "Breeze October tie-out against the filed 3B" do
    setup do
      {:ok, gstr2b} =
        @fixtures
        |> Path.join("returns_R2B_33AEWPH4158J1Z3_102025.json")
        |> File.read!()
        |> Gstr2b.parse()

      filed =
        @fixtures
        |> Path.join("filed_3b.json")
        |> File.read!()
        |> Jason.decode!()

      # The ceiling and RCM figures depend only on the union of 2B rows, not
      # on how matching bucketed them, so an empty-books recon reproduces the
      # filed ITC without the (network-bound) purchase extraction.
      recon = Recon.reconcile([], gstr2b)
      itc = ItcPosition.compute(recon, [], %{})

      assembled = Gstr3b.assemble(filed["liability_31"]["a"], recon, itc)

      %{assembled: assembled, filed: filed}
    end

    test "every Table 4 cell ties to the paise", %{assembled: assembled, filed: filed} do
      assert assembled["itc"] == filed["itc"]
    end

    test "3.1(d) reverse charge ties", %{assembled: assembled, filed: filed} do
      assert assembled["liability_31"]["d"] == filed["liability_31"]["d"]
    end

    test "6.1 set-off reproduces the filed payment, cash to the rupee", %{
      assembled: assembled,
      filed: filed
    } do
      assert assembled["setoff_61"] == filed["setoff_61"]
      assert assembled["setoff_61"]["cash_total"] == 6_024_300
    end
  end

  describe "liability_from_gstr1/1" do
    test "sums rate buckets across parties into head-wise paise" do
      derived = %{
        "b2b" => [
          %{
            "ctin" => "33AABCP9487A1ZG",
            "inv" => [
              %{
                "itms" => [
                  %{"itm_det" => %{"txval" => 100.0, "camt" => 9.0, "samt" => 9.0, "iamt" => 0}},
                  %{"itm_det" => %{"txval" => 50.5, "camt" => 0, "samt" => 0, "iamt" => 14.14}}
                ]
              }
            ]
          },
          %{
            "ctin" => "33AAVCS8021P1ZM",
            "inv" => [
              %{
                "itms" => [
                  %{"itm_det" => %{"txval" => 10.0, "camt" => 0.9, "samt" => 0.9, "iamt" => 0}}
                ]
              }
            ]
          }
        ]
      }

      assert Gstr3b.liability_from_gstr1(derived) == %{
               "txval" => 16_050,
               "igst" => 1_414,
               "cgst" => 990,
               "sgst" => 990
             }
    end

    test "subtracts positive-valued registered credit-note buckets exactly once" do
      derived = %{
        "b2b" => [
          %{
            "inv" => [
              %{
                "inum" => "I-1",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 2000,
                      "camt" => 180,
                      "samt" => 180,
                      "iamt" => 0
                    }
                  }
                ]
              }
            ]
          }
        ],
        "cdnr" => [
          %{
            "nt" => [
              %{
                "nt_num" => "CN-1",
                "ntty" => "C",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 500,
                      "camt" => 45,
                      "samt" => 45,
                      "iamt" => 0
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      assert Gstr3b.liability_from_gstr1(derived) == %{
               "txval" => 150_000,
               "igst" => 0,
               "cgst" => 13_500,
               "sgst" => 13_500
             }
    end

    test "adds positive-valued registered debit-note buckets exactly once" do
      derived = %{
        "b2b" => [
          %{
            "inv" => [
              %{
                "inum" => "INV-1",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 100_000,
                      "camt" => 0,
                      "samt" => 0,
                      "iamt" => 18_000
                    }
                  }
                ]
              }
            ]
          }
        ],
        "cdnr" => [
          %{
            "nt" => [
              %{
                "nt_num" => "CDN-000001",
                "ntty" => "D",
                "itms" => [
                  %{
                    "itm_det" => %{
                      "rt" => 18,
                      "txval" => 10_000,
                      "camt" => 0,
                      "samt" => 0,
                      "iamt" => 1_800
                    }
                  }
                ]
              }
            ]
          }
        ]
      }

      assert Gstr3b.liability_from_gstr1(derived) == %{
               "txval" => 11_000_000,
               "igst" => 1_980_000,
               "cgst" => 0,
               "sgst" => 0
             }
    end

    test "credit and debit note effects cancel exactly once in a mixed month" do
      detail = fn txval, tax ->
        %{"itm_det" => %{"rt" => 18, "txval" => txval, "camt" => 0, "samt" => 0, "iamt" => tax}}
      end

      derived = %{
        "b2b" => [%{"inv" => [%{"inum" => "INV-1", "itms" => [detail.(100_000, 18_000)]}]}],
        "cdnr" => [
          %{
            "nt" => [
              %{"nt_num" => "CN-1", "ntty" => "C", "itms" => [detail.(10_000, 1_800)]},
              %{"nt_num" => "DN-1", "ntty" => "D", "itms" => [detail.(10_000, 1_800)]}
            ]
          }
        ]
      }

      assert Gstr3b.liability_from_gstr1(derived) == %{
               "txval" => 10_000_000,
               "igst" => 1_800_000,
               "cgst" => 0,
               "sgst" => 0
             }
    end

    test "includes B2CS and B2CL once in 3.1(a) and discloses interstate unregistered in 3.2" do
      detail = fn txval, igst ->
        %{"itm_det" => %{"rt" => 18, "txval" => txval, "camt" => 0, "samt" => 0, "iamt" => igst}}
      end

      derived = %{
        "b2cs" => [
          %{
            "pos" => "29",
            "typ" => "OE",
            "sply_ty" => "INTER",
            "rt" => 18,
            "txval" => 161_016.95,
            "iamt" => 28_983.05,
            "camt" => 0,
            "samt" => 0,
            "csamt" => 0
          },
          %{
            "pos" => "33",
            "typ" => "OE",
            "sply_ty" => "INTRA",
            "rt" => 18,
            "txval" => 42_372.88,
            "iamt" => 0,
            "camt" => 3_813.56,
            "samt" => 3_813.56,
            "csamt" => 0
          }
        ],
        "b2cl" => [
          %{
            "pos" => "29",
            "inv" => [%{"inum" => "INV-000006", "itms" => [detail.(93_220.34, 16_779.66)]}]
          }
        ]
      }

      assert Gstr3b.liability_from_gstr1(derived) == %{
               "txval" => 29_661_017,
               "igst" => 4_576_271,
               "cgst" => 381_356,
               "sgst" => 381_356
             }

      assert Gstr3b.interstate_unregistered_from_gstr1(derived) == [
               %{"pos" => "29", "txval" => 25_423_729, "igst" => 4_576_271}
             ]
    end

    test "Table 3.2 disclosure does not add to payable a second time" do
      liability = %{"txval" => 100_000, "igst" => 18_000, "cgst" => 0, "sgst" => 0}
      disclosure = [%{"pos" => "29", "txval" => 100_000, "igst" => 18_000}]

      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => []
      }

      itc = ItcPosition.compute(recon, [], %{})

      assembled = Gstr3b.assemble(liability, recon, itc, disclosure)

      assert assembled["interstate_32"]["unregistered"] == disclosure
      assert assembled["setoff_61"]["other"]["igst"]["payable"] == 18_000
    end

    test "names a note-only negative position as unsupported" do
      liability = %{"txval" => -100_000, "igst" => 0, "cgst" => -9_000, "sgst" => -9_000}
      gstr3b = %{"liability_31" => %{"a" => liability}}

      assert Gstr3b.negative_outward_liability?(gstr3b)

      refute Gstr3b.negative_outward_liability?(%{
               "liability_31" => %{
                 "a" => Map.new(liability, fn {key, value} -> {key, abs(value)} end)
               }
             })
    end
  end

  describe "purchase credit and debit notes" do
    test "real portal credit-note totals become the same head-wise 4B(2) reversal" do
      portal = @december_fixture |> File.read!() |> Jason.decode!()
      {:ok, gstr2b} = Gstr2b.parse(portal)
      recon = Recon.reconcile([], gstr2b)
      itc = ItcPosition.compute(recon, [], %{})
      liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
      result = Gstr3b.assemble(liability, recon, itc)
      cdnr = get_in(portal, ["data", "itcsumm", "itcavl", "othersup", "cdnr"])

      assert result["itc"]["reversed_4b2"] == %{
               "igst" => round((cdnr["igst"] || 0) * 100),
               "cgst" => round((cdnr["cgst"] || 0) * 100),
               "sgst" => round((cdnr["sgst"] || 0) * 100)
             }
    end

    test "debit-note ITC enters 4A and supplier credit-note tax reverses in 4B(2)" do
      g2b = fn number, type, tax ->
        %{
          "vendor_gstin" => "33AAACS1234A1Z9",
          "invoice_number" => number,
          "document_type" => type,
          "taxable_paise" => 0,
          "tax_paise" => %{"igst" => tax, "cgst" => 0, "sgst" => 0},
          "reverse_charge" => false
        }
      end

      recon = %{
        "matched" => [%{"gstr2b" => g2b.("INV-1", "invoice", 18_000)}],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => [
          %{"gstr2b" => g2b.("DN-1", "debit_note", 1_800)},
          %{"gstr2b" => g2b.("CN-1", "credit_note", 3_600)}
        ]
      }

      itc = ItcPosition.compute(recon, [], %{})
      liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
      result = Gstr3b.assemble(liability, recon, itc)

      assert result["itc"]["all_other_itc_4a5"] ==
               %{"igst" => 19_800, "cgst" => 0, "sgst" => 0}

      assert result["itc"]["reversed_4b2"] ==
               %{"igst" => 3_600, "cgst" => 0, "sgst" => 0}

      assert result["itc"]["net_itc_4c"] ==
               %{"igst" => 16_200, "cgst" => 0, "sgst" => 0}

      refute Gstr3b.negative_net_itc?(result)
    end

    test "names a note-only negative ITC position as unsupported" do
      credit = %{
        "vendor_gstin" => "33AAACS1234A1Z9",
        "invoice_number" => "CN-ONLY",
        "document_type" => "credit_note",
        "tax_paise" => %{"igst" => 3_600, "cgst" => 0, "sgst" => 0},
        "reverse_charge" => false
      }

      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => [%{"gstr2b" => credit}]
      }

      itc = ItcPosition.compute(recon, [], %{})
      liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
      result = Gstr3b.assemble(liability, recon, itc)

      assert result["itc"]["net_itc_4c"]["igst"] == -3_600
      assert Gstr3b.negative_net_itc?(result)
      assert result["setoff_61"]["cash_total"] == 0
    end
  end

  describe "Rule 88A set-off ordering" do
    test "IGST credit exhausts self then spills CGST before SGST; CGST/SGST never cross" do
      liability = %{"txval" => 0, "igst" => 10_000, "cgst" => 20_000, "sgst" => 20_000}

      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => [
          %{
            "gstr2b" => %{
              "taxable_paise" => 0,
              "tax_paise" => %{"igst" => 25_000, "cgst" => 5_000, "sgst" => 5_000},
              "reverse_charge" => false
            }
          }
        ]
      }

      itc = ItcPosition.compute(recon, [], %{})
      setoff = Gstr3b.assemble(liability, recon, itc)["setoff_61"]

      # IGST 250 pays IGST 100 fully, spills 150 into CGST; CGST credit 50
      # tops CGST up; SGST pays only from its own 50.
      assert setoff["other"]["igst"] == %{
               "payable" => 10_000,
               "itc_igst" => 10_000,
               "itc_cgst" => 0,
               "itc_sgst" => 0,
               "cash" => 0
             }

      assert setoff["other"]["cgst"] == %{
               "payable" => 20_000,
               "itc_igst" => 15_000,
               "itc_cgst" => 5_000,
               "itc_sgst" => 0,
               "cash" => 0
             }

      assert setoff["other"]["sgst"] == %{
               "payable" => 20_000,
               "itc_igst" => 0,
               "itc_cgst" => 0,
               "itc_sgst" => 5_000,
               "cash" => 15_000
             }

      assert setoff["cash_total"] == 15_000
    end
  end

  describe "confirmed blocks become Table 4B reversals" do
    setup do
      recon = %{
        "matched" => [],
        "value_mismatch" => [],
        "needs_human" => [],
        "in_books_not_2b" => [],
        "in_2b_not_books" => [
          %{
            "gstr2b" => %{
              "taxable_paise" => 100_000,
              "tax_paise" => %{"igst" => 0, "cgst" => 9_000, "sgst" => 9_000},
              "reverse_charge" => false
            }
          }
        ]
      }

      row = %{
        "id" => "inv_01",
        "vendor_name" => "GAYATHRI",
        "vendor_gstin" => "33AAA0000A1Z5",
        "invoice_number" => "434",
        "igst_paise" => 0,
        "cgst_paise" => 500,
        "sgst_paise" => 500,
        "flags" => [
          %{"code" => "personal_expense_17_5", "section" => "17(5)(g)", "reason" => "residential"}
        ]
      }

      %{recon: recon, row: row, liability: %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}}
    end

    test "a recommended-but-unconfirmed block does not reverse", ctx do
      itc = ItcPosition.compute(ctx.recon, [ctx.row], %{})
      assembled = Gstr3b.assemble(ctx.liability, ctx.recon, itc)

      assert assembled["itc"]["reversed_4b1"] == %{"igst" => 0, "cgst" => 0, "sgst" => 0}
      assert assembled["itc"]["net_itc_4c"]["cgst"] == 9_000
    end

    test "a human-confirmed 17(5) block lands in 4B(1) and reduces 4C", ctx do
      block_id = ItcPosition.block_id("inv_01", "personal_expense_17_5")
      itc = ItcPosition.compute(ctx.recon, [ctx.row], %{block_id => "block_itc"})
      assembled = Gstr3b.assemble(ctx.liability, ctx.recon, itc)

      assert assembled["itc"]["reversed_4b1"] == %{"igst" => 0, "cgst" => 500, "sgst" => 500}
      assert assembled["itc"]["net_itc_4c"] == %{"igst" => 0, "cgst" => 8_500, "sgst" => 8_500}
    end
  end
end
