defmodule Nila.Banking.StatementWorker do
  @moduledoc """
  Reads one native bank PDF into a reconciled structured artifact. The worker
  never uses OCR and clears the encrypted source password after the attempt.
  """
  # Extraction is deterministic and the PDF password is deliberately erased
  # after the attempt, so retrying the same job cannot improve the result.
  use Oban.Worker, queue: :banking, max_attempts: 1

  alias Nila.Banking
  alias Nila.Banking.Statement
  alias Nila.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"statement_id" => statement_id}}) do
    case Nila.Repo.fetch(Statement, statement_id) do
      {:ok, statement} -> extract(statement)
      {:error, :not_found} -> {:cancel, :statement_deleted}
    end
  end

  defp extract(statement) do
    statement = Banking.mark_extracting(statement)
    Banking.broadcast(statement, :extracting)

    with {:ok, bytes} <- Storage.get(statement.source_key),
         {:ok, artifact} <-
           extractor().extract(bytes,
             bank_code: statement.bank_code,
             password: password(statement.source_credentials)
           ) do
      statement = Banking.mark_ready(statement, artifact)
      Banking.broadcast(statement, :ready)
      :ok
    else
      {:error, reason} -> fail(statement, reason)
    end
  rescue
    exception -> fail(statement, {:unexpected, Exception.message(exception)})
  end

  defp fail(statement, reason) do
    statement = Banking.mark_failed(statement, reason)
    Banking.broadcast(statement, :failed)
    {:error, reason}
  end

  defp password(%{"password" => password}), do: password
  defp password(_credentials), do: nil

  defp extractor do
    Application.get_env(:nila, :bank_statement_extractor, Nila.Banking.Extractor.TextPdf)
  end
end
