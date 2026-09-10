defmodule Nila.Gst.Sales.Tally.Workbench do
  @moduledoc "Atomically saves sales invoice corrections and their Tally posting selections."

  alias Nila.Gst.Sales.Batch
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Repo
  alias Nila.TallyMappings

  @doc "Atomically saves one reviewed invoice and all Tally posting selections."
  def save_workbench(
        org_id,
        client_id,
        batch_ref,
        source_id,
        company_id,
        attrs,
        corrected_by_id \\ nil
      )

  def save_workbench(
        org_id,
        client_id,
        batch_ref,
        source_id,
        company_id,
        attrs,
        corrected_by_id
      )
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_binary(source_id) and is_integer(company_id) and is_map(attrs) and
             (is_nil(corrected_by_id) or is_integer(corrected_by_id)) do
    Repo.transact(fn ->
      save_workbench_in_transaction(
        org_id,
        client_id,
        batch_ref,
        source_id,
        company_id,
        attrs,
        corrected_by_id
      )
    end)
  end

  def save_workbench(
        _org_id,
        _client_id,
        _batch_ref,
        _source_id,
        _company_id,
        _attrs,
        _corrected_by_id
      ),
      do: {:error, :invalid_workbench_submission}

  @doc "Atomically pins a Sales batch and saves one reviewed invoice's posting selections."
  def save_batch_workbench(
        org_id,
        client_id,
        batch_ref,
        batch_id,
        source_id,
        company_id,
        attrs,
        corrected_by_id
      )
      when is_integer(org_id) and is_integer(client_id) and is_binary(batch_ref) and
             is_integer(batch_id) and is_binary(source_id) and is_integer(company_id) and
             is_map(attrs) and (is_nil(corrected_by_id) or is_integer(corrected_by_id)) do
    Repo.transact(fn ->
      with {:ok, batch} <- Batch.pin_destination_in_transaction(org_id, batch_id, company_id),
           {:ok, result} <-
             save_workbench_in_transaction(
               org_id,
               client_id,
               batch_ref,
               source_id,
               company_id,
               attrs,
               corrected_by_id
             ) do
        {:ok, Map.put(result, :sales_batch, batch)}
      end
    end)
  end

  def save_batch_workbench(
        _org_id,
        _client_id,
        _batch_ref,
        _batch_id,
        _source_id,
        _company_id,
        _attrs,
        _corrected_by_id
      ),
      do: {:error, :invalid_workbench_submission}

  defp save_workbench_in_transaction(
         org_id,
         client_id,
         batch_ref,
         source_id,
         company_id,
         attrs,
         corrected_by_id
       ) do
    with {:ok, submission} <- normalize_workbench_attrs(attrs),
         {:ok, correction_result} <-
           InvoiceCorrections.save_in_transaction(
             org_id,
             client_id,
             batch_ref,
             source_id,
             submission.invoice,
             corrected_by_id
           ),
         {:ok, posting_result} <-
           TallyMappings.save_sales_posting_in_transaction(
             org_id,
             company_id,
             party_identity(correction_result.invoice, source_id),
             submission.party_ledger_identity,
             submission.posting_profile
           ),
         {:ok, line_mappings} <-
           TallyMappings.save_sales_ledger_choices_in_transaction(
             org_id,
             company_id,
             correction_result.invoice,
             submission.line_sales_ledger_identities
           ) do
      {:ok,
       correction_result
       |> Map.merge(posting_result)
       |> Map.put(:line_mappings, line_mappings)}
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalize_workbench_attrs(attrs) do
    invoice = attr(attrs, :invoice)
    party_ledger_identity = attr(attrs, :party_ledger_identity)
    posting_profile = attr(attrs, :posting_profile)
    line_sales_ledger_identities = attr(attrs, :line_sales_ledger_identities)

    if is_map(invoice) and is_binary(party_ledger_identity) and is_map(posting_profile) and
         is_map(line_sales_ledger_identities) do
      {:ok,
       %{
         invoice: invoice,
         party_ledger_identity: party_ledger_identity,
         posting_profile: posting_profile,
         line_sales_ledger_identities: line_sales_ledger_identities
       }}
    else
      {:error, :invalid_workbench_submission}
    end
  end

  defp party_identity(invoice, source_id) do
    %{
      gstin: invoice["buyer_gstin"],
      name: invoice["buyer_name"],
      source_key: source_id
    }
  end
end
