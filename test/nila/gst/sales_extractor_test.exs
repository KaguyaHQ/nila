defmodule Nila.Gst.SalesExtractorTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Gstr1
  alias Nila.Gst.SalesExtractor.{LlamaExtract, Stub}

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
               "20/2026-27",
               "21/2026-27",
               "22/2026-27"
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

  describe "LlamaExtract.pages/2 (pure response mapping)" do
    test "reshapes per-page results and attaches rendered image basenames" do
      body = %{
        "extract_result" => [
          %{
            "page" => 1,
            "data" => %{"invoice_number" => "20/2026-27"},
            "confidence" => %{"x" => 0.9}
          },
          %{"page" => 2, "data" => %{"invoice_number" => "21/2026-27"}}
        ]
      }

      images = %{"page_01.png" => <<0>>}

      [first, second] = LlamaExtract.pages(body, images)

      assert first["page"] == 1
      assert first["image"] == "images/page_01.png"
      assert first["data"]["invoice_number"] == "20/2026-27"
      assert first["confidence"] == %{"x" => 0.9}

      # No rendered image for page 2 → image and confidence stay nil.
      assert second["image"] == nil
      assert second["confidence"] == nil
    end

    test "returns [] when the response has no recognizable page list" do
      assert LlamaExtract.pages(%{"status" => "COMPLETED"}, %{}) == []
    end
  end
end
