defmodule Nila.Documents.Extractor.LlamaExtractTest do
  @moduledoc """
  Pure-mapping tests against a captured real LlamaExtract response (the Philips →
  Breezetech PO). No network — the HTTP path is exercised manually in dev.
  """
  use ExUnit.Case, async: true

  alias Nila.Documents.Extractor.LlamaExtract

  @fixture "test/support/fixtures/llama_extract_response.json"

  setup do
    body = @fixture |> File.read!() |> Jason.decode!()
    %{result: LlamaExtract.map_result(body)}
  end

  test "wraps the result in the canonical artifact envelope", %{result: result} do
    assert result["kind"] == "purchase_order_extraction"
    assert result["version"] == 1
    assert is_map(result["data"])
  end

  test "maps the PO header fields", %{result: %{"data" => data}} do
    assert data["po_number"] == "4700329424"
    assert data["po_date"] == "18.05.2026"
    assert data["place_of_supply"] =~ "Tamil Nadu"
  end

  test "does NOT swap supplier (Order-to) and buyer (Payer)", %{result: %{"data" => data}} do
    # supplier = us (BREEZETECH), buyer = the customer we invoice (Philips)
    assert data["supplier_name"] == "BREEZETECH"
    assert data["supplier_gstin"] == "33AEWPH4158J1Z3"
    assert data["buyer_name"] == "Philips India Limited"
    assert data["buyer_gstin"] == "33AABCP9487A1ZG"
  end

  test "maps the line item with the CGST/SGST split and null IGST", %{result: %{"data" => data}} do
    assert [line] = data["line_items"]
    assert line["hsn_sac"] == "998719"
    assert line["cgst_amount"] == "4447.80"
    assert line["sgst_amount"] == "4447.80"
    # intra-state TN→TN — no IGST
    assert line["igst_amount"] in [nil, "0.00"]
  end

  test "maps totals as plain decimal strings", %{result: %{"data" => data}} do
    assert data["subtotal"] == "49420.00"
    assert data["grand_total"] == "58315.60"
  end

  test "flattens per-field confidence and flags nothing on a clean PO", %{result: result} do
    assert result["confidence"]["buyer_gstin"] == 1.0
    assert result["confidence"]["supplier_gstin"] == 1.0
    assert result["exceptions"] == []
  end

  test "captures the parse job id for traceability", %{result: result} do
    assert is_binary(result["_source"]["parse_job_id"])
  end
end
