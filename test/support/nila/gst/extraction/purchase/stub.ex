defmodule Nila.Gst.Extraction.Purchase.Stub do
  @moduledoc """
  Deterministic purchase extractor used only by tests.

  Returns a handful of real-looking per-page artifacts (valid GSTINs, an
  intra-state and inter-state bill, a continuation page) plus tiny placeholder
  page images, so the month worker, `Nila.Gst.Purchase.Books` assembly, reconciliation,
  and evidence storage all run with no network. Same role the bank/PO stubs play.
  """
  @behaviour Nila.Gst.Extraction.Purchase

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
      page(1, %{
        "is_invoice" => true,
        "continuation_of_previous" => false,
        "invoice_number" => "DPS-0072",
        "invoice_date" => "08/10/2025",
        "seller" => %{
          "name" => "DAWN POWER SOLUTIONS",
          "gstin" => "32AAMFD7558A1ZL",
          "state" => "Kerala (32)"
        },
        "buyer" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "line_items" => [
          %{
            "description" => "ECM DIAGNOSIS SCANNING",
            "hsn_sac" => "9987",
            "quantity" => 1.0,
            "taxable_value" => 17_000.00,
            "igst_rate" => 18.0,
            "igst_amount" => 3060.00
          }
        ],
        "printed_grand_total" => 20_060.00
      }),
      page(2, %{
        "is_invoice" => true,
        "continuation_of_previous" => false,
        "invoice_number" => "GS015056",
        "invoice_date" => "10/10/2025",
        "seller" => %{
          "name" => "MONY STORES",
          "gstin" => "32ABZPT4063A1ZJ",
          "state" => "Kerala (32)"
        },
        "buyer" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "line_items" => [
          %{
            "description" => "HARDWARE SUNDRIES",
            "hsn_sac" => "7318",
            "quantity" => 1.0,
            "taxable_value" => 373.15,
            "igst_rate" => 18.0,
            "igst_amount" => 67.17
          }
        ],
        "printed_grand_total" => 440.32
      }),
      page(3, %{
        "is_invoice" => true,
        "continuation_of_previous" => false,
        "invoice_number" => "G2744",
        "invoice_date" => "12/10/2025",
        "seller" => %{
          "name" => "INTER COOL REFRIGERATION",
          "gstin" => "32ACVPR7455F1Z3",
          "state" => "Kerala (32)"
        },
        "buyer" => %{"name" => "BREEZE TECH", "gstin" => "33AEWPH4158J1Z3"},
        "line_items" => [
          %{
            "description" => "COMPRESSOR SERVICE",
            "hsn_sac" => "8415",
            "quantity" => 1.0,
            "taxable_value" => 805.08,
            "igst_rate" => 18.0,
            "igst_amount" => 144.91
          }
        ],
        "printed_grand_total" => 949.99
      })
    ]
  end

  defp page(number, data) do
    padded = number |> to_string() |> String.pad_leading(2, "0")

    %{
      "kind" => "purchase_invoice_extraction",
      "version" => 1,
      "page" => number,
      "source_pages" => [number],
      "source_attribution" => %{"status" => "verified", "candidate_pages" => [number]},
      "image" => "images/page_#{padded}.png",
      "data" => data,
      "confidence" => nil
    }
  end
end
