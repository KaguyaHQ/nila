defmodule Nila.Gst.Extraction.SalesTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Sales.Gstr1
  alias Nila.Gst.Extraction.Sales.Stub

  describe "Stub.extract/2" do
    test "returns per-page artifacts with matching images that Gstr1 can normalize" do
      {:ok, %{pages: pages, images: images}} = Stub.extract(<<>>, filename: "sales.pdf")

      assert length(pages) == 3

      for page <- pages do
        assert page["kind"] == "gstr1_sales_invoice_extraction"
        assert Map.has_key?(images, Path.basename(page["image"]))
      end

      invoices = Enum.map(pages, &Gstr1.normalize_invoice/1)

      assert Enum.map(invoices, & &1["invoice_number"]) == [
               "20/2025-26",
               "21/2025-26",
               "22/2025-26"
             ]
    end

    test "page 1 carries the poison-total canary the validator must flag" do
      {:ok, %{pages: pages}} = Stub.extract(<<>>, [])

      invoices = Enum.map(pages, &Gstr1.normalize_invoice/1)
      codes = invoices |> Gstr1.validation_issues() |> Enum.map(& &1["code"])

      assert "grand_total_mismatch" in codes
    end

    test "invokes on_progress with the coarse stages" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_progress = fn stage -> Agent.update(agent, &[stage | &1]) end

      {:ok, _} = Stub.extract(<<>>, on_progress: on_progress)

      stages = agent |> Agent.get(&Enum.reverse/1)
      assert stages == [:rendering, :reading, :extracting]
    end
  end
end
