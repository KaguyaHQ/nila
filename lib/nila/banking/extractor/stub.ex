defmodule Nila.Banking.Extractor.Stub do
  @moduledoc """
  Deterministic fake bank-statement extractor used in dev (no API key) and
  tests. Returns a canonical Indian-bank statement shape — a handful of
  real-looking lines (UPI credits, an NEFT, a debit) — so the worker,
  projection, and `/bank` display all work offline. Same role the PO stub plays.
  """
  @behaviour Nila.Banking.Extractor

  @impl true
  def extract(_pdf_bytes, opts) do
    on_progress = Keyword.get(opts, :on_progress, fn _stage -> :ok end)

    on_progress.(:reading)
    on_progress.(:extracting)

    {:ok,
     %{
       "kind" => "bank_statement_extraction",
       "version" => 1,
       "account" => %{
         "account_number_masked" => "4021",
         "ifsc" => "HDFC0000123",
         "bank_name" => "HDFC Bank",
         "label" => "HDFC Current A/c"
       },
       "transactions" => [
         %{
           "txn_date" => "2026-05-02",
           "value_date" => "2026-05-02",
           "amount" => "12500.00",
           "direction" => "credit",
           "balance" => "112500.00",
           "narration" => "UPI/CR/241023456789/RAMESH KUMAR/HDFC/Payment",
           "ref" => "241023456789",
           "mode" => "upi"
         },
         %{
           "txn_date" => "2026-05-04",
           "value_date" => "2026-05-04",
           "amount" => "8400.00",
           "direction" => "credit",
           "balance" => "120900.00",
           "narration" => "UPI/CR/241125789012/SUNDAR TRADERS/ICIC/Invoice",
           "ref" => "241125789012",
           "mode" => "upi"
         },
         %{
           "txn_date" => "2026-05-07",
           "value_date" => "2026-05-07",
           "amount" => "45000.00",
           "direction" => "credit",
           "balance" => "165900.00",
           "narration" => "NEFT CR-SBIN0001234-PHILIPS INDIA LIMITED-PO 4700329424",
           "ref" => "SBIN26050712345",
           "mode" => "neft"
         },
         %{
           "txn_date" => "2026-05-09",
           "value_date" => "2026-05-09",
           "amount" => "18750.00",
           "direction" => "debit",
           "balance" => "147150.00",
           "narration" => "UPI/DR/241345678901/BHARAT PETROLEUM/SBIN/Fuel",
           "ref" => "241345678901",
           "mode" => "upi"
         },
         %{
           "txn_date" => "2026-05-12",
           "value_date" => "2026-05-12",
           "amount" => "60000.00",
           "direction" => "debit",
           "balance" => "87150.00",
           "narration" => "NEFT DR-ICIC0000456-SUPPLIER STEEL WORKS",
           "ref" => "ICIC26051298765",
           "mode" => "neft"
         }
       ]
     }}
  end
end
