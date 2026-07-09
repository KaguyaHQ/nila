defmodule Nila.Gst.FlagsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Flags

  # Valid checksummed GSTINs (Tamil Nadu 33, Maharashtra 27).
  @tn_vendor_gstin "33AAACR5055K1ZE"
  @mh_vendor_gstin "27AABCI4851P1Z3"
  @entity_gstin "33AABCC6407D1Z9"

  @entity_ctx %{
    "gstin" => @entity_gstin,
    "state_code" => "33",
    "registered_address" => "Plot 12, Ambattur Industrial Estate, Chennai, Tamil Nadu 600058",
    "business_hsn_prefixes" => ["8471", "8473", "9983"],
    "residential_markers" => ["Jasmine Apartments", "Anna Nagar"]
  }

  defp invoice(attrs) do
    Map.merge(
      %{
        "id" => "inv_1",
        "vendor_name" => "Redington Distribution Pvt Ltd",
        "vendor_gstin" => @tn_vendor_gstin,
        "invoice_number" => "RD/2026/0042",
        "invoice_date" => ~D[2026-06-14],
        "taxable_paise" => 10_000_00,
        "tax_paise" => %{"cgst" => 900_00, "sgst" => 900_00, "igst" => 0},
        "total_paise" => 11_800_00,
        "line_items" => [
          %{
            "description" => "Laptop docking station",
            "hsn_sac" => "847330",
            "taxable_paise" => 10_000_00
          }
        ],
        "delivery_address" => "Plot 12, Ambattur Industrial Estate, Chennai, Tamil Nadu 600058"
      },
      attrs
    )
  end

  defp codes(flags), do: Enum.map(flags, & &1["code"])

  defp only(flags, code), do: Enum.filter(flags, &(&1["code"] == code))

  describe "clean invoice" do
    test "a plausible business purchase fires nothing" do
      assert Flags.evaluate(invoice(%{}), @entity_ctx) == []
    end

    test "fires nothing even with a matching vendor directory entry" do
      vendor_dir = %{@tn_vendor_gstin => "Redington Distribution"}
      assert Flags.evaluate(invoice(%{}), @entity_ctx, vendor_dir) == []
    end
  end

  describe "invalid_gstin" do
    test "flags a GSTIN with a bad check digit as an error, naming the GSTIN" do
      bad = "33AAACR5055K1ZF"

      [flag] =
        invoice(%{"vendor_gstin" => bad}) |> Flags.evaluate(@entity_ctx) |> only("invalid_gstin")

      assert flag["severity"] == "error"
      assert flag["reason"] =~ bad
      assert flag["fields"] == ["vendor_gstin"]
    end
  end

  describe "own_gstin_as_vendor" do
    test "flags the entity's own GSTIN appearing as vendor" do
      [flag] =
        invoice(%{"vendor_gstin" => @entity_gstin})
        |> Flags.evaluate(@entity_ctx)
        |> only("own_gstin_as_vendor")

      assert flag["severity"] == "error"
      assert flag["reason"] =~ @entity_gstin
    end
  end

  describe "gstin_state_mismatch" do
    test "inter-state vendor charging CGST/SGST warns with IGST Act s.10" do
      [flag] =
        invoice(%{"vendor_gstin" => @mh_vendor_gstin})
        |> Flags.evaluate(@entity_ctx)
        |> only("gstin_state_mismatch")

      assert flag["severity"] == "warning"
      assert flag["section"] == "IGST Act s.10"
      assert flag["reason"] =~ @mh_vendor_gstin
      assert flag["reason"] =~ "Maharashtra"
    end

    test "intra-state vendor charging IGST warns" do
      [flag] =
        invoice(%{"tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 1_800_00}})
        |> Flags.evaluate(@entity_ctx)
        |> only("gstin_state_mismatch")

      assert flag["severity"] == "warning"
      assert flag["reason"] =~ "IGST"
    end

    test "inter-state vendor charging IGST is clean" do
      flags =
        invoice(%{
          "vendor_gstin" => @mh_vendor_gstin,
          "tax_paise" => %{"cgst" => 0, "sgst" => 0, "igst" => 1_800_00}
        })
        |> Flags.evaluate(@entity_ctx)

      refute "gstin_state_mismatch" in codes(flags)
    end
  end

  describe "name_gstin_mismatch" do
    # Threshold 0.75: trade-vs-legal variants of the same vendor score >= 0.82
    # under Nila.Fuzzy's prefix/substring boosts ("Redington Distribution" vs
    # "Redington Distribution Pvt Ltd"), while unrelated names score 0.50-0.65
    # on raw Jaro — 0.75 splits those populations.
    test "flags when the 2B trade name shares nothing with the invoice name" do
      vendor_dir = %{@tn_vendor_gstin => "Sundaram Textiles Private Limited"}

      [flag] =
        invoice(%{}) |> Flags.evaluate(@entity_ctx, vendor_dir) |> only("name_gstin_mismatch")

      assert flag["severity"] == "review"
      assert flag["reason"] =~ "Redington Distribution Pvt Ltd"
      assert flag["reason"] =~ "Sundaram Textiles Private Limited"
    end

    test "does not flag a trade-vs-legal name variant" do
      vendor_dir = %{@tn_vendor_gstin => "Redington Distribution"}
      flags = Flags.evaluate(invoice(%{}), @entity_ctx, vendor_dir)

      refute "name_gstin_mismatch" in codes(flags)
    end

    test "silent when the GSTIN is absent from the directory" do
      vendor_dir = %{"27ZZZZZ0000Z1Z5" => "Someone Else"}
      flags = Flags.evaluate(invoice(%{}), @entity_ctx, vendor_dir)

      refute "name_gstin_mismatch" in codes(flags)
    end
  end

  describe "hsn_implausible" do
    test "flags a line whose HSN starts with no business prefix" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "Ceramic floor tiles",
              "hsn_sac" => "690721",
              "taxable_paise" => 10_000_00
            }
          ]
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("hsn_implausible")

      assert flag["severity"] == "review"
      assert flag["reason"] =~ "Ceramic floor tiles"
      assert flag["reason"] =~ "690721"
    end

    test "silent when the line has no HSN or the entity lists no prefixes" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "Ceramic floor tiles",
              "hsn_sac" => nil,
              "taxable_paise" => 10_000_00
            }
          ]
        })

      assert inv |> Flags.evaluate(@entity_ctx) |> only("hsn_implausible") == []

      ctx = Map.put(@entity_ctx, "business_hsn_prefixes", [])

      inv2 =
        invoice(%{
          "line_items" => [
            %{"description" => "Tiles", "hsn_sac" => "690721", "taxable_paise" => 10_000_00}
          ]
        })

      assert inv2 |> Flags.evaluate(ctx) |> only("hsn_implausible") == []
    end
  end

  describe "personal_expense_17_5" do
    test "the fridge case: Croma refrigerator to a residential address fires 17(5)(g) with the amount" do
      inv =
        invoice(%{
          "vendor_name" => "Croma",
          "vendor_gstin" => @tn_vendor_gstin,
          "taxable_paise" => 42_000_00,
          "total_paise" => 49_560_00,
          "tax_paise" => %{"cgst" => 3_780_00, "sgst" => 3_780_00, "igst" => 0},
          "line_items" => [
            %{
              "description" => "LG 260L Double Door Refrigerator",
              "hsn_sac" => "841810",
              "taxable_paise" => 42_000_00
            }
          ],
          "delivery_address" => "Flat 4B, Jasmine Apartments, Velachery, Chennai 600042"
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")

      assert flag["severity"] == "review"
      assert flag["section"] == "CGST Act 17(5)(g)"
      assert flag["reason"] =~ "₹42,000.00"
      assert flag["reason"] =~ "Refrigerator"
      assert flag["reason"] =~ "Jasmine Apartments"
      assert "delivery_address" in flag["fields"]
      refute flag["reason"] =~ ~r/ineligible|disallowed|blocked\.|denied/i
    end

    test "motor vehicle description maps to 17(5)(a)" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "Honda Activa motorcycle",
              "hsn_sac" => "871120",
              "taxable_paise" => 80_000_00
            }
          ]
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")
      assert flag["section"] == "CGST Act 17(5)(a)"
    end

    test "catering description maps to 17(5)(b)" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "Outdoor catering for annual day",
              "hsn_sac" => "996334",
              "taxable_paise" => 55_000_00
            }
          ]
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")
      assert flag["section"] == "CGST Act 17(5)(b)"
    end

    test "residential delivery alone (no blocked item) still routes for review" do
      inv = invoice(%{"delivery_address" => "No 8, Anna Nagar 2nd Avenue, Chennai 600040"})

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")

      assert flag["severity"] == "review"
      assert flag["section"] == "CGST Act 17(5)(g)"
      assert flag["reason"] =~ "Anna Nagar"
    end

    test "business delivery to the registered address with a business item is clean" do
      assert invoice(%{}) |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5") == []
    end

    test "own address with OCR noise and reformatting does not flag (October regression)" do
      noisy_variants = [
        "M/s. ENTITY\nPlot 12 Ambattur Indl Estate\nChennai-58",
        "Plot 12, AMBATTUR INDUSTRIAL ESTATE,\nCHENNAI-600 058, Tamil Nadu",
        "plot 12 ambattur estate chennai"
      ]

      for delivery <- noisy_variants do
        inv = invoice(%{"delivery_address" => delivery})

        assert inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5") == [],
               "false positive on own-address variant: #{inspect(delivery)}"
      end
    end

    test "bare city or state token is not treated as evidence of a different place" do
      for delivery <- ["CHENNAI", "TAMILNADU"] do
        inv = invoice(%{"delivery_address" => delivery})

        assert inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5") == [],
               "false positive on uninformative address: #{inspect(delivery)}"
      end
    end

    test "genuinely different city still flags" do
      inv = invoice(%{"delivery_address" => "14 Gandhi Road, Visakhapatnam 530001"})

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")
      assert flag["severity"] == "review"
    end

    test "paint product named BEAUTY SHEEN does not match health/beauty services (October regression)" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "4LT KNP BEAUTY SHEEN BSH1 MORNING FROST-7361",
              "hsn_sac" => "3209",
              "taxable_paise" => 72_034
            }
          ]
        })

      assert inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5") == []
    end

    test "beauty parlour service still flags 17(5)(b)" do
      inv =
        invoice(%{
          "line_items" => [
            %{
              "description" => "Beauty parlour services for staff event",
              "hsn_sac" => "999721",
              "taxable_paise" => 15_000_00
            }
          ]
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("personal_expense_17_5")
      assert flag["section"] == "CGST Act 17(5)(b)"
    end
  end

  describe "duplicate_invoice" do
    test "same vendor GSTIN + invoice number scanned twice flags both rows naming pages and ITC" do
      a = invoice(%{"id" => "inv_14", "pages" => [15], "invoice_number" => "254111"})
      b = invoice(%{"id" => "inv_46", "pages" => [48], "invoice_number" => "254111"})

      flags = Flags.evaluate_all([a, b], @entity_ctx)

      [fa] = only(flags["inv_14"], "duplicate_invoice")
      [fb] = only(flags["inv_46"], "duplicate_invoice")

      assert fa["severity"] == "warning"
      assert fa["reason"] =~ "pages 15, 48"
      assert fa["reason"] =~ "inv_46"
      assert fa["reason"] =~ "₹1,800.00"
      assert fb["reason"] =~ "inv_14"
    end

    test "different invoice numbers from the same vendor do not flag" do
      a = invoice(%{"id" => "a", "invoice_number" => "254111"})
      b = invoice(%{"id" => "b", "invoice_number" => "254112"})

      flags = Flags.evaluate_all([a, b], @entity_ctx)
      assert only(flags["a"], "duplicate_invoice") == []
      assert only(flags["b"], "duplicate_invoice") == []
    end

    test "missing invoice numbers never group as duplicates" do
      a = invoice(%{"id" => "a", "invoice_number" => nil})
      b = invoice(%{"id" => "b", "invoice_number" => nil})

      flags = Flags.evaluate_all([a, b], @entity_ctx)
      assert only(flags["a"], "duplicate_invoice") == []
    end
  end

  describe "missing_gstin" do
    test "flags an invoice with no vendor GSTIN, naming the total at risk" do
      [flag] =
        invoice(%{"vendor_gstin" => nil})
        |> Flags.evaluate(@entity_ctx)
        |> only("missing_gstin")

      assert flag["severity"] == "review"
      assert flag["reason"] =~ "₹11,800.00"
      assert flag["reason"] =~ "Redington"
    end
  end

  describe "tax_arithmetic_off" do
    test "flags line-sum vs invoice-taxable drift beyond 100 paise" do
      inv =
        invoice(%{
          "taxable_paise" => 10_000_00,
          "line_items" => [
            %{
              "description" => "Laptop docking station",
              "hsn_sac" => "847330",
              "taxable_paise" => 9_500_00
            }
          ]
        })

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("tax_arithmetic_off")

      assert flag["severity"] == "warning"
      assert flag["reason"] =~ "₹9,500.00"
      assert flag["reason"] =~ "₹10,000.00"
    end

    test "flags CGST/SGST halves differing by more than 1 paise" do
      inv = invoice(%{"tax_paise" => %{"cgst" => 900_00, "sgst" => 850_00, "igst" => 0}})

      [flag] = inv |> Flags.evaluate(@entity_ctx) |> only("tax_arithmetic_off")

      assert flag["severity"] == "warning"
      assert flag["reason"] =~ "₹900.00"
      assert flag["reason"] =~ "₹850.00"
    end

    test "tolerates rounding-level drift" do
      inv =
        invoice(%{
          "taxable_paise" => 10_000_50,
          "tax_paise" => %{"cgst" => 900_00, "sgst" => 900_01, "igst" => 0}
        })

      assert inv |> Flags.evaluate(@entity_ctx) |> only("tax_arithmetic_off") == []
    end
  end

  describe "evaluate_all/3" do
    test "groups flags by invoice id" do
      clean = invoice(%{"id" => "inv_clean"})
      dirty = invoice(%{"id" => "inv_dirty", "vendor_gstin" => nil})

      result = Flags.evaluate_all([clean, dirty], @entity_ctx)

      assert result["inv_clean"] == []
      assert [%{"code" => "missing_gstin"}] = result["inv_dirty"]
    end
  end

  describe "confession_rows/1" do
    test "selects only review flags and formats routed-to-human rows" do
      flags =
        invoice(%{
          "vendor_gstin" => nil,
          "tax_paise" => %{"cgst" => 900_00, "sgst" => 850_00, "igst" => 0}
        })
        |> Flags.evaluate(@entity_ctx)

      assert "tax_arithmetic_off" in codes(flags)

      [row] = Flags.confession_rows(flags)

      assert row["invoice_id"] == "inv_1"
      assert row["summary"] =~ "could not classify"
      assert row["summary"] =~ "routed to human"
      assert row["why"] =~ "No vendor GSTIN"
    end
  end
end
