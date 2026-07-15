defmodule Mix.Tasks.Nila.ImportBankStatement do
  @shortdoc "Imports a bank statement PDF and enqueues extraction"

  @moduledoc """
  Imports a bank statement file into Nila storage, creates the document record,
  and enqueues `Nila.Documents.BankStatementExtractionWorker` to extract and
  project transactions.

      mix nila.import_bank_statement PATH --org ORG_ID

  Pass `--org` to attribute the imported statement to a firm.
  """

  use Mix.Task

  alias Nila.Documents.Import

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [org: :integer])

    path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix nila.import_bank_statement PATH --org ORG_ID")
      end

    Mix.Task.run("app.start")

    org_id = resolve_org_id(opts)

    case Import.import_bank_statement_from_path(path, org_id: org_id) do
      {:ok, document} ->
        Mix.shell().info(
          "Imported bank statement ##{document.id} (#{document.filename}); extraction enqueued."
        )

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  defp resolve_org_id(opts) do
    case Keyword.get(opts, :org) do
      nil -> Mix.raise("Pass --org ORG_ID")
      org_id -> org_id
    end
  end
end
