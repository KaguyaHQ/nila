defmodule Nila.Gst.Filing.Gstr3bTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.Gstr3b

  test "explicit treatment claims carried heads without a later reversal" do
    recon = %{
      "matched" => [],
      "value_mismatch" => [],
      "in_2b_not_books" => [],
      "in_books_not_2b" => [],
      "needs_human" => []
    }

    claim = %{"igst" => 1_200, "cgst" => 300, "sgst" => 200, "cess" => 50}
    liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
    result = Gstr3b.assemble(liability, recon, %{"current_claim_heads" => claim})

    assert result["itc"]["net_itc_4c"] == claim
    assert result["itc"]["reversed_4b1"] == %{"igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0}
    assert result["itc"]["reversed_4b2"] == %{"igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0}
  end

  test "supplier credit notes reduce treated credit, including a note-only negative month" do
    note = %{
      "document_type" => "credit_note",
      "invoice_number" => "CN-1",
      "taxable_paise" => 1_000,
      "tax_paise" => %{"igst" => 200, "cgst" => 0, "sgst" => 0, "cess" => 25},
      "total_paise" => 1_225
    }

    recon = %{
      "matched" => [],
      "value_mismatch" => [],
      "in_2b_not_books" => [%{"gstr2b" => note}],
      "in_books_not_2b" => [],
      "needs_human" => []
    }

    liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}

    with_claim =
      Gstr3b.assemble(liability, recon, %{
        "current_claim_heads" => %{"igst" => 1_000, "cgst" => 0, "sgst" => 0, "cess" => 100}
      })

    assert with_claim["itc"]["net_itc_4c"]["igst"] == 800
    assert with_claim["itc"]["net_itc_4c"]["cess"] == 75

    note_only =
      Gstr3b.assemble(liability, recon, %{
        "current_claim_heads" => %{"igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0}
      })

    assert note_only["itc"]["net_itc_4c"]["igst"] == -200
    assert note_only["itc"]["net_itc_4c"]["cess"] == -25
    assert Gstr3b.negative_net_itc?(note_only)
  end

  test "RCM credit follows treated cases rather than the current 2B RCM total" do
    rcm = %{
      "document_type" => "invoice",
      "invoice_number" => "RCM-1",
      "reverse_charge" => true,
      "taxable_paise" => 2_500,
      "tax_paise" => %{"igst" => 500, "cgst" => 0, "sgst" => 0},
      "total_paise" => 3_000
    }

    recon = %{
      "matched" => [],
      "value_mismatch" => [],
      "in_2b_not_books" => [%{"gstr2b" => rcm}],
      "in_books_not_2b" => [],
      "needs_human" => []
    }

    liability = %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}
    normal_claim = %{"igst" => 1_000, "cgst" => 0, "sgst" => 0, "cess" => 0}

    deferred_rcm =
      Gstr3b.assemble(liability, recon, %{
        "current_claim_heads" => normal_claim,
        "rcm_claim_heads" => %{"igst" => 0}
      })

    assert deferred_rcm["liability_31"]["d"]["igst"] == 500
    assert deferred_rcm["itc"]["rcm_4a3"]["igst"] == 0
    assert deferred_rcm["itc"]["all_other_itc_4a5"]["igst"] == 1_000

    carried_rcm =
      Gstr3b.assemble(
        liability,
        %{
          "matched" => [],
          "value_mismatch" => [],
          "in_2b_not_books" => [],
          "in_books_not_2b" => [],
          "needs_human" => []
        },
        %{
          "current_claim_heads" => %{normal_claim | "igst" => 500},
          "rcm_claim_heads" => %{"igst" => 500}
        }
      )

    assert carried_rcm["itc"]["rcm_4a3"]["igst"] == 500
    assert carried_rcm["itc"]["all_other_itc_4a5"]["igst"] == 0
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

      itc = %{"current_claim_heads" => %{"igst" => 0, "cgst" => 0, "sgst" => 0, "cess" => 0}}

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

      itc = %{
        "current_claim_heads" => %{
          "igst" => 25_000,
          "cgst" => 5_000,
          "sgst" => 5_000,
          "cess" => 0
        }
      }

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
end
