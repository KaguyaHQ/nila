defmodule Nila.Gst.Sales.Review.MonthChecks do
  @moduledoc "Evidence-bound confirmations for the three sales packet checks."
  alias Nila.Gst.Sales.Workings

  @codes ~w(sequence_gaps pages_unaccounted evidence_unavailable)

  def request_basis(issue, latest_decision) do
    {issue["basis"], latest_decision && latest_decision.id}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  def supported?(issue) do
    issue["code"] in @codes and is_nil(issue["invoice"]) and
      is_nil(issue["source_id"]) and issue["source_ids"] in [nil, []] and
      not Workings.blocking?(issue)
  end

  # Include source identities, not only messages: different uploads can have the
  # same filename, and a corrected bill can leave the same gap in the sequence.
  def bind(issue, invoices, packet) do
    if supported?(issue) do
      basis =
        {1, Map.drop(issue, ["status", "basis"]), source_facts(invoices), packet}
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      Map.put(issue, "basis", basis)
    else
      issue
    end
  end

  defp source_facts(invoices) do
    Enum.map(invoices, fn invoice ->
      invoice
      |> Map.delete("taxpayer_checks")
      |> Map.update("line_items", [], fn lines ->
        Enum.map(lines, &Map.drop(&1, ["hsn_validation", "hsn_description_signal"]))
      end)
    end)
  end

  def confirmed?(issue, confirmation) do
    if supported?(issue) do
      is_binary(issue["basis"]) and
        get_in(confirmation || %{}, ["payload", "basis"]) == issue["basis"]
    else
      not is_nil(confirmation)
    end
  end
end
