defmodule Nila.Gst.Filing.TallyPrimeTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.TallyPrime

  test "requires the selected Tally company to have the client's GSTIN" do
    assert :ok =
             TallyPrime.validate_company_gstin(
               %{gstin: "33aewph4158j1z3"},
               "33AEWPH4158J1Z3"
             )

    assert {:error, :tally_company_gstin_missing} =
             TallyPrime.validate_company_gstin(%{gstin: nil}, "33AEWPH4158J1Z3")

    assert {:error, {:tally_company_gstin_mismatch, _, _}} =
             TallyPrime.validate_company_gstin(
               %{gstin: "29AAVCS8021P1ZB"},
               "33AEWPH4158J1Z3"
             )
  end

  test "builds GST-aware accounting invoices for every active sales document" do
    projection = %{
      invoices: [
        invoice(%{
          "id" => "sales_month_1_inv_01",
          "invoice_number" => "INV&001",
          "buyer_name" => "Customer & Co",
          "line_items" => [
            %{
              "description" => "Equipment maintenance",
              "hsn_sac" => "998719",
              "taxable_value" => 1_000,
              "igst_rate" => 18,
              "igst_amount" => 180
            }
          ]
        }),
        invoice(%{
          "id" => "sales_month_1_inv_02",
          "document_type" => "credit_note",
          "invoice_number" => "CN-001",
          "recipient_registration" => "unregistered",
          "buyer_name" => nil,
          "buyer_gstin" => nil,
          "place_of_supply" => "33",
          "line_items" => [
            %{
              "description" => "Equipment maintenance",
              "hsn_sac" => "998719",
              "taxable_value" => 200,
              "cgst_rate" => 9,
              "sgst_rate" => 9,
              "cgst_amount" => 18,
              "sgst_amount" => 18
            }
          ]
        }),
        invoice(%{"invoice_number" => "CANCELLED-001", "document_status" => "cancelled"})
      ]
    }

    assert {:ok, xml} = TallyPrime.build(projection)

    assert xml =~ "<TALLYREQUEST>Import</TALLYREQUEST>"
    assert xml =~ "<IMPORTDUPS>@@DUPIGNORE</IMPORTDUPS>"

    assert xml =~
             ~r/<VOUCHER REMOTEID="[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}"/

    assert xml =~
             ~r/<GUID>[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}<\/GUID>/

    assert xml =~
             ~s(VCHTYPE="Sales" ACTION="Create" OBJVIEW="Invoice Voucher View")

    assert xml =~ "<VOUCHERNUMBER>INV&amp;001</VOUCHERNUMBER>"
    assert xml =~ "<PARTYLEDGERNAME>Customer &amp; Co</PARTYLEDGERNAME>"
    assert xml =~ "<PARTYNAME>Customer &amp; Co</PARTYNAME>"
    assert xml =~ "<PARTYGSTIN>29AAVCS8021P1ZB</PARTYGSTIN>"
    assert xml =~ "<PLACEOFSUPPLY>Karnataka</PLACEOFSUPPLY>"
    assert xml =~ "<GSTREGISTRATIONTYPE>Regular</GSTREGISTRATIONTYPE>"
    assert xml =~ "<ISINVOICE>Yes</ISINVOICE>"
    assert xml =~ "<PERSISTEDVIEW>Invoice Voucher View</PERSISTEDVIEW>"
    assert xml =~ "<ISGSTOVERRIDDEN>Yes</ISGSTOVERRIDDEN>"
    assert xml =~ "<LEDGERENTRIES.LIST>"
    assert xml =~ "<ISLASTDEEMEDPOSITIVE>No</ISLASTDEEMEDPOSITIVE>"
    refute xml =~ "<ALLLEDGERENTRIES.LIST>"
    assert xml =~ "<LEDGERNAME>Customer &amp; Co</LEDGERNAME>"
    assert xml =~ "<AMOUNT>-1180.00</AMOUNT>"
    assert xml =~ "<LEDGERNAME>Sales</LEDGERNAME>"
    assert xml =~ "<GSTOVRDNTAXABILITY>Taxable</GSTOVRDNTAXABILITY>"
    assert xml =~ "<GSTOVRDNTYPEOFSUPPLY>Services</GSTOVRDNTYPEOFSUPPLY>"
    assert xml =~ "<GSTHSNNAME>998719</GSTHSNNAME>"
    assert xml =~ "<GSTHSNDESCRIPTION>Equipment maintenance</GSTHSNDESCRIPTION>"
    assert xml =~ "<GSTRATEDUTYHEAD>IGST</GSTRATEDUTYHEAD>"
    assert xml =~ "<GSTRATE>18</GSTRATE>"
    assert xml =~ "<AMOUNT>1000.00</AMOUNT>"
    assert xml =~ "<LEDGERNAME>Output IGST</LEDGERNAME>"
    assert xml =~ "<AMOUNT>180.00</AMOUNT>"

    assert xml =~ ~s(VCHTYPE="Credit Note" ACTION="Create")
    assert xml =~ "<PARTYLEDGERNAME>Cash</PARTYLEDGERNAME>"
    assert xml =~ "<AMOUNT>236.00</AMOUNT>"
    assert xml =~ "<AMOUNT>-200.00</AMOUNT>"
    assert xml =~ "<LEDGERNAME>Output CGST</LEDGERNAME>"
    assert xml =~ "<AMOUNT>-18.00</AMOUNT>"
    assert xml =~ "<LEDGERNAME>Output SGST</LEDGERNAME>"
    refute xml =~ "CANCELLED-001"
  end

  test "posts the envelope and returns Tally's import counts" do
    caller = self()

    response = """
    <ENVELOPE>
      <HEADER><VERSION>1</VERSION><STATUS>1</STATUS></HEADER>
      <BODY><DATA><IMPORTRESULT>
        <CREATED>1</CREATED><ALTERED>0</ALTERED><COMBINED>0</COMBINED>
        <IGNORED>0</IGNORED><ERRORS>0</ERRORS>
      </IMPORTRESULT></DATA></BODY>
    </ENVELOPE>
    """

    request = fn xml ->
      send(caller, {:request, xml})
      {:ok, %{status: 200, body: response}}
    end

    assert {:ok,
            %{
              created: 1,
              altered: 0,
              combined: 0,
              ignored: 0,
              errors: 0,
              exceptions: 0,
              line_errors: []
            }} = TallyPrime.push(%{invoices: [invoice()]}, request: request)

    assert_receive {:request, xml}
    assert xml =~ "<VOUCHERNUMBER>INV-001</VOUCHERNUMBER>"
  end

  test "generates a real random correlation UUID for each newly built delivery" do
    assert {:ok, first_xml} = TallyPrime.build(%{active_invoices: [invoice()]})
    assert {:ok, second_xml} = TallyPrime.build(%{active_invoices: [invoice()]})

    [first_id] = Regex.run(~r/REMOTEID="([^"]+)"/, first_xml, capture: :all_but_first)
    [second_id] = Regex.run(~r/REMOTEID="([^"]+)"/, second_xml, capture: :all_but_first)

    assert {:ok, decoded} = Ecto.UUID.dump(first_id)
    assert <<_::48, 4::4, _::12, 2::2, _::62>> = decoded
    refute second_id == first_id
  end

  test "builds an explicitly company-scoped connector import" do
    assert {:ok, xml, 1} =
             TallyPrime.build_for_company(%{invoices: [invoice()]}, "Nila & Co")

    assert xml =~ "<SVCURRENTCOMPANY>Nila &amp; Co</SVCURRENTCOMPANY>"
  end

  test "builds one independently identifiable import per voucher" do
    projection = %{
      invoices: [invoice(), invoice(%{"id" => "second", "invoice_number" => "INV-002"})],
      period: "2026-07"
    }

    assert {:ok, [first, second]} = TallyPrime.build_items_for_company(projection, "Nila")
    assert first.invoice_number == "INV-001"
    assert first.voucher_type == "Sales"
    assert second.invoice_number == "INV-002"
    assert first.source_id != second.source_id
    assert byte_size(first.source_id) == 64
    assert first.ledger_names == ["Customer", "Sales", "Output IGST"]
    assert length(Regex.scan(~r/<TALLYMESSAGE>/, first.xml)) == 1
    assert first.xml =~ "<SVCURRENTCOMPANY>Nila</SVCURRENTCOMPANY>"
  end

  test "accepts Tally's direct response format without a status tag" do
    response = """
    <RESPONSE>
      <CREATED>0</CREATED><ALTERED>1</ALTERED><COMBINED>0</COMBINED>
      <IGNORED>0</IGNORED><ERRORS>0</ERRORS><EXCEPTIONS>0</EXCEPTIONS>
    </RESPONSE>
    """

    assert {:ok, %{created: 0, altered: 1}} = TallyPrime.parse_response(response, 1)
  end

  test "rejects a direct response carrying an explicit failure status" do
    response = """
    <RESPONSE>
      <STATUS>0</STATUS><CREATED>0</CREATED><ERRORS>0</ERRORS><EXCEPTIONS>0</EXCEPTIONS>
    </RESPONSE>
    """

    assert {:error, {:tally_rejected, %{created: 0}}} =
             TallyPrime.parse_response(response, 1)
  end

  test "rejects a successful response that does not account for the whole batch" do
    response = """
    <RESPONSE>
      <CREATED>1</CREATED><ALTERED>0</ALTERED><COMBINED>0</COMBINED>
      <IGNORED>0</IGNORED><ERRORS>0</ERRORS><EXCEPTIONS>0</EXCEPTIONS>
    </RESPONSE>
    """

    assert {:error, {:partial_import, %{created: 1}}} = TallyPrime.parse_response(response, 2)
  end

  test "returns Tally's line error and preserves partial-import counts" do
    response = """
    <ENVELOPE>
      <HEADER><STATUS>0</STATUS></HEADER>
      <BODY><DATA><IMPORTRESULT>
        <CREATED>1</CREATED><ERRORS>1</ERRORS>
        <LINEERROR>Ledger Customer &amp; Co does not exist</LINEERROR>
      </IMPORTRESULT></DATA></BODY>
    </ENVELOPE>
    """

    assert {:error,
            {:tally_rejected,
             %{
               created: 1,
               errors: 1,
               line_errors: ["Ledger Customer & Co does not exist"]
             }}} = TallyPrime.parse_response(response)
  end

  test "uses the duplicate-excluded effective projection and accepts legacy active status" do
    retained = invoice(%{"id" => "retained", "document_status" => nil})
    excluded = invoice(%{"id" => "excluded", "invoice_number" => "DUP-001"})

    assert {:ok, xml} =
             TallyPrime.build(%{
               invoices: [retained, excluded],
               active_invoices: [retained]
             })

    assert xml =~ "INV-001"
    refute xml =~ "DUP-001"
  end

  test "derives the party amount from rounded paise postings so the voucher balances" do
    line = %{
      "description" => "Equipment maintenance",
      "hsn_sac" => "998719",
      "taxable_value" => 10.005,
      "cgst_rate" => 9,
      "sgst_rate" => 9,
      "cgst_amount" => 0.905,
      "sgst_amount" => 0.905,
      "igst_amount" => nil
    }

    assert {:ok, xml} =
             TallyPrime.build(%{
               invoices: [invoice(%{"place_of_supply" => "33", "line_items" => [line]})]
             })

    assert xml =~ "<AMOUNT>-11.83</AMOUNT>"
    assert xml =~ "<AMOUNT>10.01</AMOUNT>"
    assert xml =~ "<AMOUNT>0.91</AMOUNT>"
  end

  test "refuses empty or incomplete active sales data before posting" do
    assert {:error, :no_active_sales} = TallyPrime.build(%{invoices: []})

    assert {:error, :invalid_sales_data} =
             TallyPrime.build(%{invoices: [invoice(%{"invoice_date" => nil})]})
  end

  test "refuses contradictory GST tax heads before posting" do
    mixed_line = %{
      "description" => "Equipment maintenance",
      "hsn_sac" => "998719",
      "taxable_value" => 1_000,
      "cgst_rate" => 9,
      "cgst_amount" => 90,
      "igst_rate" => 18,
      "igst_amount" => 180
    }

    assert {:error, :invalid_sales_data} =
             TallyPrime.build(%{invoices: [invoice(%{"line_items" => [mixed_line]})]})

    intrastate =
      invoice(%{
        "place_of_supply" => "33",
        "line_items" => [
          %{
            "description" => "Equipment maintenance",
            "hsn_sac" => "998719",
            "taxable_value" => 1_000,
            "igst_rate" => 18,
            "igst_amount" => 180
          }
        ]
      })

    assert {:error, :invalid_sales_data} = TallyPrime.build(%{invoices: [intrastate]})
  end

  test "refuses line postings that do not conserve the printed invoice total" do
    mismatched = invoice(%{"printed_grand_total" => 1_179})

    assert {:error, :invalid_sales_data} = TallyPrime.build(%{invoices: [mismatched]})
  end

  defp invoice(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "sales_month_1_inv_01",
        "document_type" => "invoice",
        "document_status" => "active",
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2026-07-15],
        "seller_gstin" => "33AEWPH4158J1Z3",
        "buyer_name" => "Customer",
        "buyer_gstin" => "29AAVCS8021P1ZB",
        "place_of_supply" => "29",
        "recipient_registration" => "registered",
        "line_items" => [
          %{
            "description" => "Equipment maintenance",
            "hsn_sac" => "998719",
            "taxable_value" => 1_000,
            "igst_rate" => 18,
            "cgst_amount" => nil,
            "sgst_amount" => nil,
            "igst_amount" => 180
          }
        ]
      },
      overrides
    )
  end
end
