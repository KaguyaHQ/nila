defmodule Nila.Gst.SalesExtractor.Stub do
  @moduledoc """
  Deterministic offline sales extractor used in dev (no API key) and tests.

  Returns a handful of real-looking per-page sales-invoice artifacts (valid
  GSTINs, intra-state CGST/SGST lines, the poison-total canary on page 1) plus
  tiny placeholder page images, so the GSTR-1 worker, `Gstr1` derivation,
  validation, and evidence storage all run with no network. The outward mirror
  of `Nila.Gst.PurchaseExtractor.Stub`.
  """
  @behaviour Nila.Gst.SalesExtractor

  # 1x1 transparent PNG — stands in for a rendered page scan.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  @impl true
  def extract(_pdf_bytes, opts) do
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)

    on_progress.(:rendering)
    on_progress.(:reading)
    on_progress.(:extracting)

    {:ok, %{pages: pages(), images: images()}}
  end

  defp images do
    for page <- pages(), into: %{}, do: {Path.basename(page["image"]), @png}
  end

  defp pages do
    [
      # Page 1 carries the poison-total canary: printed grand total (2,75,000)
      # disagrees with the line sum (64,552 + tax) — validation must flag it,
      # never silently trust the printed total.
      page(1, %{
        "invoice_number" => "20/2026-27",
        "invoice_date" => "04.05.2026",
        "seller" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => [
          line("Refrigeration unit", "8415", 55_552.0, 9.0),
          line("Installation service", "9987", 4_500.0, 9.0),
          line("Gas charge", "2903", 1_500.0, 9.0),
          line("Transport", "9987", 3_000.0, 9.0)
        ],
        "printed_total_taxable" => 64_552.0,
        "printed_total_tax" => 11_619.36,
        "printed_grand_total" => 2_75_000.00
      }),
      page(2, %{
        "invoice_number" => "21/2026-27",
        "invoice_date" => "06.05.2026",
        "seller" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "PONMANI AND CO", "gstin" => "33AABCP9487A1ZG"},
        "line_items" => [line("AC service", "8415", 12_000.0, 9.0)],
        "printed_total_taxable" => 12_000.0,
        "printed_total_tax" => 2_160.0,
        "printed_grand_total" => 14_160.0
      }),
      page(3, %{
        "invoice_number" => "22/2026-27",
        "invoice_date" => "09.05.2026",
        "seller" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "buyer" => %{"name" => "SIEMENS HEALTHCARE", "gstin" => "33AAVCS8021P1ZM"},
        "line_items" => [line("134A Gas", "2903", 10_200.0, 9.0)],
        "printed_total_taxable" => 10_200.0,
        "printed_total_tax" => 1_836.0,
        "printed_grand_total" => 12_036.0
      })
    ]
  end

  # Intra-state line: CGST + SGST at the same rate, no IGST.
  defp line(description, hsn, taxable, side_rate) do
    side = Float.round(taxable * side_rate / 100, 2)

    %{
      "description" => description,
      "hsn_sac" => hsn,
      "quantity" => 1.0,
      "taxable_value" => taxable,
      "cgst_rate" => side_rate,
      "cgst_amount" => side,
      "sgst_rate" => side_rate,
      "sgst_amount" => side
    }
  end

  defp page(number, data) do
    padded = number |> to_string() |> String.pad_leading(2, "0")

    %{
      "kind" => "gstr1_sales_invoice_extraction",
      "version" => 1,
      "page" => number,
      "image" => "images/page_#{padded}.png",
      "data" => data,
      "confidence" => nil
    }
  end
end
