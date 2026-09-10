defmodule Nila.Gst.Extraction.TaxComponentsTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.{TaxComponents, Verify}

  test "resolves complete printed invoice tax components without using lines" do
    for {components, expected} <- [
          {[{"IGST", 900}], 900},
          {[{"CGST", 450.01}, {"SGST", 450.02}], 900.03},
          {[{"IGST", 0}], 0},
          {[{"Tax Amount", 900}, {"IGST", 900}], 900},
          {[{"CGST", 450}], nil},
          {[{"IGST", 900}, {"SGST", 450}], nil},
          {[{"CGST", 450}, {"SGST", nil}], nil},
          {[{"IGST", 900}, {"IGST", 900}], nil},
          {[{"IGST", 900}, {"Unknown", 1}], nil},
          {[], nil}
        ] do
      invoice = %{
        "printed_tax_totals" =>
          Enum.map(components, fn {label, amount} ->
            %{"printed_label" => label, "printed_amount" => amount}
          end),
        "line_items" => [%{"igst_amount" => 900}]
      }

      assert TaxComponents.printed_tax_total(invoice) == expected
    end
  end

  test "explicit printed total takes precedence over components, including zero" do
    for amount <- [0, 901] do
      invoice = %{
        "printed_total_tax" => amount,
        "printed_tax_totals" => [%{"printed_label" => "IGST", "printed_amount" => 900}]
      }

      assert TaxComponents.printed_tax_total(invoice) == amount
    end
  end

  test "projects a printed IGST component without losing its source evidence" do
    component = %{
      "printed_label" => "IGST",
      "printed_rate" => 18,
      "printed_amount" => 19_998.72
    }

    data = TaxComponents.project(%{"line_items" => [%{"printed_tax_components" => [component]}]})
    [line] = data["line_items"]

    assert line["printed_tax_components"] == [component]
    assert line["igst_rate"] == 18
    assert line["igst_amount"] == 19_998.72
    assert line["cgst_rate"] == nil
    assert line["sgst_rate"] == nil
    refute Map.has_key?(line, "tax_component_issues")
  end

  test "projects separately printed CGST and SGST components" do
    components = [
      %{"printed_label" => "CGST", "printed_rate" => 9, "printed_amount" => 90},
      %{"printed_label" => "SGST", "printed_rate" => 9, "printed_amount" => 90}
    ]

    data = TaxComponents.project(%{"line_items" => [%{"printed_tax_components" => components}]})
    [line] = data["line_items"]

    assert line["cgst_rate"] == 9
    assert line["cgst_amount"] == 90
    assert line["sgst_rate"] == 9
    assert line["sgst_amount"] == 90
    assert line["igst_rate"] == nil
  end

  test "an empty component list clears canonical tax heads" do
    line = %{
      "printed_tax_components" => [],
      "igst_rate" => 18,
      "igst_amount" => 180
    }

    assert %{"line_items" => [projected]} =
             TaxComponents.project(%{"line_items" => [line]})

    assert projected["igst_rate"] == nil
    assert projected["igst_amount"] == nil
    refute Map.has_key?(projected, "tax_component_issues")
  end

  test "unknown and duplicate printed labels remain evidence and are flagged" do
    components = [
      %{"printed_label" => "GST", "printed_rate" => 18, "printed_amount" => 180},
      %{"printed_label" => "IGST", "printed_rate" => 18, "printed_amount" => 180},
      %{"printed_label" => "I.G.S.T.", "printed_rate" => 18, "printed_amount" => 180}
    ]

    data = TaxComponents.project(%{"line_items" => [%{"printed_tax_components" => components}]})
    [line] = data["line_items"]

    assert line["igst_rate"] == nil

    assert Enum.map(line["tax_component_issues"], & &1["kind"]) == [
             "unknown_tax_label",
             "duplicate_tax_head"
           ]

    assert %{status: :flagged, flags: flags} = Verify.structured(data)
    assert {:tax_component_issue, issues} = List.keyfind(flags, :tax_component_issue, 0)
    assert Enum.all?(issues, &(&1["line"] == 0))
  end

  test "canonical tax fields cannot substitute for missing printed components" do
    line = %{"igst_rate" => 18, "igst_amount" => 180}

    assert %{"line_items" => [projected]} = TaxComponents.project(%{"line_items" => [line]})
    assert projected["igst_rate"] == nil
    assert projected["igst_amount"] == nil
  end

  test "projects explicitly labelled invoice tax totals" do
    totals = [
      %{"printed_label" => "Total CGST", "printed_amount" => 90},
      %{"printed_label" => "Add: SGST", "printed_amount" => 90}
    ]

    projected =
      TaxComponents.project(%{
        "printed_tax_totals" =>
          totals ++
            [%{"printed_label" => "Total Tax", "printed_amount" => 180}],
        "line_items" => []
      })

    assert projected["printed_tax_totals"] ==
             totals ++
               [%{"printed_label" => "Total Tax", "printed_amount" => 180}]

    assert projected["printed_cgst"] == 90
    assert projected["printed_sgst"] == 90
    assert projected["printed_igst"] == nil
    assert projected["printed_total_tax"] == 180
    refute Map.has_key?(projected, "tax_total_issues")
  end

  test "a generic combined tax total does not become a canonical tax head" do
    projected =
      TaxComponents.project(%{
        "printed_tax_totals" => [
          %{"printed_label" => "Tax Amount", "printed_amount" => 180}
        ],
        "printed_total_tax" => 180,
        "printed_cgst" => 180,
        "line_items" => []
      })

    assert projected["printed_cgst"] == nil
    assert projected["printed_sgst"] == nil
    assert projected["printed_igst"] == nil
    assert projected["printed_total_tax"] == 180
  end

  test "unknown and duplicate invoice tax totals are preserved and flagged" do
    totals = [
      %{"printed_label" => "GST", "printed_amount" => 180},
      %{"printed_label" => "IGST", "printed_amount" => 180},
      %{"printed_label" => "Total IGST", "printed_amount" => 180}
    ]

    projected =
      TaxComponents.project(%{"printed_tax_totals" => totals, "line_items" => []})

    assert projected["printed_tax_totals"] == totals
    assert projected["printed_igst"] == nil

    assert Enum.map(projected["tax_total_issues"], & &1["kind"]) == [
             "unknown_tax_label",
             "duplicate_tax_head"
           ]

    assert %{status: :flagged, flags: flags} = Verify.structured(projected)
    assert {:tax_component_issue, _issues} = List.keyfind(flags, :tax_component_issue, 0)
  end

  test "canonical invoice totals cannot substitute for missing printed components" do
    data = %{"printed_igst" => 180, "printed_total_tax" => 180, "line_items" => []}

    projected = TaxComponents.project(data)
    assert projected["printed_igst"] == nil
    assert projected["printed_total_tax"] == nil
  end

  test "projection replaces old issues and repeating it does not duplicate them" do
    data = %{
      "printed_tax_totals" => [%{"printed_label" => "Unknown", "printed_amount" => 180}],
      "line_items" => [
        %{
          "printed_tax_components" => [
            %{"printed_label" => "IGST", "printed_amount" => 180},
            %{"printed_label" => "IGST", "printed_amount" => 180}
          ]
        }
      ]
    }

    projected = TaxComponents.project(data)
    assert TaxComponents.project(projected) == projected

    corrected =
      projected
      |> Map.put("printed_tax_totals", [])
      |> put_in(["line_items", Access.at(0), "printed_tax_components"], [])
      |> TaxComponents.project()

    refute Map.has_key?(corrected, "tax_total_issues")
    refute Map.has_key?(hd(corrected["line_items"]), "tax_component_issues")
  end
end
