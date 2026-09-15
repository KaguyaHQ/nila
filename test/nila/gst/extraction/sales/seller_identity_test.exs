defmodule Nila.Gst.Extraction.Sales.SellerIdentityTest do
  use ExUnit.Case, async: true
  alias Nila.Gst.Extraction.Sales.{SellerIdentity, Normalizer}
  alias Nila.Gst.Sales.Invoice.Validation

  @client "33AEHFS3648M1ZL"
  @wrong "33AEHFS3648M1ZZ"

  defp data(gstin),
    do: %{"supplier" => %{"name" => "Simple Systems", "gstin" => gstin}, "line_items" => []}

  test "client identity is used while the original seller reading survives normalization" do
    extracted = SellerIdentity.apply(data(@wrong), @client, "Seller GSTIN: #{@client}")
    invoice = Normalizer.normalize(%{"data" => extracted})
    assert invoice["seller_gstin"] == @client
    assert invoice["seller_identity"]["observed_gstin"] == @wrong
    assert invoice["seller_identity"]["status"] == "matched"

    refute Enum.any?(
             Validation.issues([invoice]),
             &(&1["code"] in ~w(invalid_gstin seller_identity_unverified seller_identity_mismatch))
           )
  end

  test "an exact seller match needs no native text, including scans" do
    assert SellerIdentity.apply(data(@client), @client, "")["seller_identity"]["status"] ==
             "matched"
  end

  test "a checksum misread still detects a bill uploaded under the wrong client" do
    result = SellerIdentity.apply(data(@wrong), "33AEWPH4158J1Z3", "GSTIN #{@client}")
    assert result["seller_identity"]["status"] == "different"
    assert result["seller_identity"]["source_gstin"] == @client
  end

  test "a different valid seller remains a review item even if client occurs elsewhere" do
    other = "33AEWPH4158J1Z3"

    invoice =
      data(other)
      |> SellerIdentity.apply(@client, "Bill to #{@client}")
      |> then(&Normalizer.normalize(%{"data" => &1}))

    assert invoice["seller_gstin"] == @client
    assert invoice["seller_identity"]["observed_gstin"] == other

    assert Enum.any?(
             Validation.issues([invoice]),
             &(&1["code"] == "seller_identity_mismatch" and &1["level"] == "required")
           )
  end

  test "invalid or absent readings need review without independent matching text" do
    for read <- [@wrong, nil, "", "29ABCDE1234F1Z9"] do
      invoice =
        data(read)
        |> SellerIdentity.apply(@client, "")
        |> then(&Normalizer.normalize(%{"data" => &1}))

      assert Enum.any?(
               Validation.issues([invoice]),
               &(&1["code"] == "seller_identity_unverified")
             )
    end
  end

  test "unrelated invalid seller cannot be cleared by buyer GSTIN or a partial text match" do
    for {read, text} <- [{"29ABCDE1234F1Z9", @client}, {@wrong, "X#{@client}Y"}] do
      assert SellerIdentity.apply(data(read), @client, text)["seller_identity"]["status"] ==
               "unverified"
    end
  end

  test "missing or invalid client master never replaces source identity" do
    for client <- [nil, "", @wrong] do
      assert SellerIdentity.apply(data(@client), client, "") == data(@client)
    end
  end
end
