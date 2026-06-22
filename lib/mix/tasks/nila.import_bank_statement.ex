defmodule Mix.Tasks.Nila.ImportBankStatement do
  @shortdoc "Imports a bank statement PDF and enqueues extraction"

  @moduledoc """
  Imports a bank statement file into Nila storage, creates the document record,
  and enqueues `Nila.Documents.BankStatementExtractionWorker` to extract and
  project transactions.

      mix nila.import_bank_statement PATH --entity ENTITY_ID
      mix nila.import_bank_statement PATH --org ORG_ID

  Pass either `--entity` (the owning legal entity, whose org is used) or `--org`
  directly. The worker projects rows under the org's default entity when the
  account can't be tied to a specific one.
  """

  use Mix.Task

  alias Nila.Documents.Import
  alias Nila.Orgs

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [entity: :integer, org: :integer])

    path =
      case positional do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix nila.import_bank_statement PATH --entity ID")
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
    cond do
      org_id = Keyword.get(opts, :org) ->
        org_id

      entity_id = Keyword.get(opts, :entity) ->
        case Orgs.get_entity(entity_id) do
          {:ok, entity} -> entity.org_id
          {:error, :not_found} -> Mix.raise("No entity with id #{entity_id}")
        end

      true ->
        Mix.raise("Pass --entity ENTITY_ID or --org ORG_ID")
    end
  end
end
