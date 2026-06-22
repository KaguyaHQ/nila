defmodule Nila.Banking.Extractor do
  @callback extract(pdf_bytes :: binary(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  # Supported opts include :filename and optional :on_progress callback.
  # The callback receives coarse stages such as :reading and :extracting.
  #
  # The returned map carries an "account" map (account_number_masked, ifsc,
  # bank_name, label) and a "transactions" list of statement lines, each with
  # txn_date, value_date, amount, direction, balance, narration, ref, mode.
end
