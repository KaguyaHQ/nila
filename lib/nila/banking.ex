defmodule Nila.Banking do
  @moduledoc """
  Bank-statement intake: a native text PDF becomes a stored, tenant-scoped
  transaction artifact before it can be exported to Tally.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Banking.Statement
  alias Nila.Repo

  @banks [{"HDFC Bank", "hdfc"}, {"Kotak Mahindra Bank / 811", "kotak"}]

  def banks, do: @banks

  def bank_name(code) do
    Enum.find_value(@banks, fn {name, value} -> value == code && name end)
  end

  def record_statement(%{org_id: org_id, client_id: client_id} = scope, attrs) do
    %Statement{
      org_id: org_id,
      client_id: client_id,
      brought_in_by_id: scope[:brought_in_by_id]
    }
    |> Statement.create_changeset(attrs)
    |> Repo.insert()
  end

  def get_statement(org_id, id) do
    Repo.fetch_one(
      from statement in Statement,
        where: statement.org_id == ^org_id and statement.id == ^id,
        preload: [:client, :brought_in_by]
    )
  end

  def mark_extracting(%Statement{} = statement) do
    statement
    |> Ecto.Changeset.change(status: "extracting", error: nil)
    |> Repo.update!()
  end

  def mark_ready(%Statement{} = statement, artifact) do
    attrs = %{
      status: "ready",
      source_credentials: nil,
      account_number_masked: artifact.account_number_masked,
      statement_from: artifact.statement_from,
      statement_to: artifact.statement_to,
      opening_balance_paise: artifact.opening_balance_paise,
      closing_balance_paise: artifact.closing_balance_paise,
      total_withdrawal_paise: artifact.total_withdrawal_paise,
      total_deposit_paise: artifact.total_deposit_paise,
      transaction_count: length(artifact.transactions),
      transactions: artifact.transactions,
      meta: artifact.meta,
      error: nil
    }

    statement |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  def mark_failed(%Statement{} = statement, reason) do
    statement
    |> Ecto.Changeset.change(
      status: "failed",
      source_credentials: nil,
      error: failure_message(reason)
    )
    |> Repo.update!()
  end

  def subscribe(org_id),
    do: Phoenix.PubSub.subscribe(Nila.PubSub, "bank_statements:#{org_id}")

  def broadcast(%Statement{} = statement, state) do
    Phoenix.PubSub.broadcast(
      Nila.PubSub,
      "bank_statements:#{statement.org_id}",
      {:bank_statement_progress, statement.id, state}
    )
  end

  defp failure_message(:password_required),
    do: "The PDF password was not accepted. Bring in the original statement and try again."

  defp failure_message(:not_text_pdf),
    do: "This PDF has no usable text layer. Bring in the bank-generated PDF, not a scan."

  defp failure_message(:unsupported_statement),
    do: "This does not look like the selected bank's statement."

  defp failure_message(:statement_does_not_tally),
    do: "The extracted transactions do not reconcile to the printed running balance."

  defp failure_message({:statement_does_not_tally, _ordinal, _expected, _printed}),
    do: failure_message(:statement_does_not_tally)

  defp failure_message(_reason),
    do: "Nila could not read this statement. Try the original PDF again."
end
