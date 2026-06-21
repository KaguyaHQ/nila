defmodule Nila.Documents.Extractor.Stub do
  @moduledoc """
  Deterministic fake extractor used in dev (no API key) and tests. Returns the
  same canonical `purchase_order_extraction` shape as
  `Nila.Documents.Extractor.LlamaExtract`, populated with the real Breezetech ←
  Philips example so the review UI and invoice preview look right offline.
  Only `po_number` varies, derived from the filename.
  """
  @behaviour Nila.Documents.Extractor

  @impl true
  def extract(_pdf_bytes, opts) do
    filename = Keyword.get(opts, :filename, "")
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)

    on_progress.(:reading)
    on_progress.(:extracting)

    {:ok,
     %{
       "kind" => "purchase_order_extraction",
       "version" => 1,
       "data" => %{
         "po_number" => po_number(filename),
         "po_date" => "18.05.2026",
         "payment_terms" => "Payment within 45 days after date of invoice",
         "place_of_supply" => "Tamil Nadu - State code 33",
         "supplier_name" => "BREEZETECH",
         "supplier_gstin" => "33AEWPH4158J1Z3",
         "supplier_address" =>
           "37/15A, Mullai Street, Kumaran Nagar Extn 2, Padi, 600050 CHENNAI, Tamil Nadu",
         "buyer_name" => "Philips India Limited",
         "buyer_gstin" => "33AABCP9487A1ZG",
         "buyer_address" =>
           "C/o. UPS SCS India Pvt Ltd. 21, MRH Road, Madhavaram, 600066 CHENNAI, Tamil Nadu",
         "ship_to_name" => "KILPAUK MEDICAL COLLEGE",
         "ship_to_address" => "822, Poonamallee High Road, 600010 CHENNAI",
         "line_items" => [
           %{
             "description" => "Labour & Mechanical Support",
             "hsn_sac" => "998719",
             "quantity" => 1,
             "unit" => "EA",
             "unit_price" => "49420.00",
             "taxable" => "49420.00",
             "cgst_rate" => 9,
             "cgst_amount" => "4447.80",
             "sgst_rate" => 9,
             "sgst_amount" => "4447.80",
             "igst_rate" => nil,
             "igst_amount" => nil,
             "tax_rate" => "18",
             "amount" => "58315.60"
           }
         ],
         "subtotal" => "49420.00",
         "tax_total" => "8895.60",
         "grand_total" => "58315.60"
       },
       "confidence" => %{
         "po_number" => 0.99,
         "buyer_gstin" => 1.0,
         "supplier_gstin" => 1.0,
         "grand_total" => 0.99,
         "hsn_sac" => 1.0
       },
       "exceptions" => []
     }}
  end

  defp po_number(filename) do
    case Regex.run(~r/(\d{6,})/, filename) do
      [_, number] -> number
      _ -> "4700329424"
    end
  end
end
