defmodule Nila.Gst.Filing.TallyPrimeTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Filing.TallyPrime

  test "builds accounting vouchers for every active sales document" do
    projection = %{
      invoices: [
        invoice(%{
          "id" => "sales_month_1_inv_01",
          "invoice_number" => "INV&001",
          "buyer_name" => "Customer & Co",
          "line_items" => [
            %{"taxable_value" => 1_000, "igst_rate" => 18, "igst_amount" => 180}
          ]
        }),
        invoice(%{
          "id" => "sales_month_1_inv_02",
          "document_type" => "credit_note",
          "invoice_number" => "CN-001",
          "recipient_registration" => "unregistered",
          "buyer_name" => nil,
          "line_items" => [
            %{
              "taxable_value" => 200,
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
    assert xml =~ ~s(<VOUCHER REMOTEID="nila-)
    assert xml =~ ~s(VCHTYPE="Sales" ACTION="Create")
    assert xml =~ "<VOUCHERNUMBER>INV&amp;001</VOUCHERNUMBER>"
    assert xml =~ "<PARTYLEDGERNAME>Customer &amp; Co</PARTYLEDGERNAME>"
    assert xml =~ "<LEDGERNAME>Customer &amp; Co</LEDGERNAME>"
    assert xml =~ "<AMOUNT>-1180.00</AMOUNT>"
    assert xml =~ "<LEDGERNAME>Sales</LEDGERNAME>"
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

  test "scopes stable voucher identity to the filing period" do
    projection = %{active_invoices: [invoice()], period: "2026-07"}

    assert {:ok, july_xml} = TallyPrime.build(projection)
    assert {:ok, repeated_xml} = TallyPrime.build(projection)
    assert {:ok, august_xml} = TallyPrime.build(%{projection | period: "2026-08"})

    [july_id] = Regex.run(~r/REMOTEID="([^"]+)"/, july_xml, capture: :all_but_first)
    [repeated_id] = Regex.run(~r/REMOTEID="([^"]+)"/, repeated_xml, capture: :all_but_first)
    [august_id] = Regex.run(~r/REMOTEID="([^"]+)"/, august_xml, capture: :all_but_first)

    assert repeated_id == july_id
    refute august_id == july_id
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
    assert second.invoice_number == "INV-002"
    assert first.source_id != second.source_id
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
      "taxable_value" => 10.005,
      "cgst_amount" => 0.905,
      "sgst_amount" => 0.905,
      "igst_amount" => nil
    }

    assert {:ok, xml} = TallyPrime.build(%{invoices: [invoice(%{"line_items" => [line]})]})

    assert xml =~ "<AMOUNT>-11.83</AMOUNT>"
    assert xml =~ "<AMOUNT>10.01</AMOUNT>"
    assert xml =~ "<AMOUNT>0.91</AMOUNT>"
  end

  test "refuses empty or incomplete active sales data before posting" do
    assert {:error, :no_active_sales} = TallyPrime.build(%{invoices: []})

    assert {:error, :invalid_sales_data} =
             TallyPrime.build(%{invoices: [invoice(%{"invoice_date" => nil})]})
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
        "recipient_registration" => "registered",
        "line_items" => [
          %{
            "taxable_value" => 1_000,
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
