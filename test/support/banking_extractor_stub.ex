defmodule Nila.Banking.Extractor.Stub do
  @behaviour Nila.Banking.Extractor

  @impl true
  def extract("fail", _opts), do: {:error, :not_text_pdf}

  def extract(_bytes, _opts) do
    {:ok,
     %{
       bank_code: "hdfc",
       account_number_masked: "•••• 4587",
       statement_from: ~D[2026-06-01],
       statement_to: ~D[2026-06-02],
       opening_balance_paise: 10_000,
       closing_balance_paise: 12_500,
       total_withdrawal_paise: 0,
       total_deposit_paise: 2_500,
       transactions: [
         %{
           "id" => "stub-1",
           "ordinal" => 1,
           "date" => ~D[2026-06-02],
           "value_date" => ~D[2026-06-02],
           "narration" => "Test credit",
           "reference" => "REF-1",
           "withdrawal_paise" => 0,
           "deposit_paise" => 2_500,
           "balance_paise" => 12_500
         }
       ],
       meta: %{"parser" => "stub", "balance_reconciled" => true}
     }}
  end
end
