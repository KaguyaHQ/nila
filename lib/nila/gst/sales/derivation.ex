defmodule Nila.Gst.Sales.Derivation do
  @moduledoc """
  Builds the outward working projection from the effective sales dumps.

  This operation runs inside the intake worker's existing transaction. It owns
  sales-specific materialization while intake continues to own dump lifecycle,
  retries and the filing wall.
  """

  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Hsn.Directory
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Issues
  alias Nila.Gst.Sales.{Gstr1, Months, Workings}

  @doc "Recalculates and saves the sales working inside the caller's intake transaction."
  def refresh_in_transaction(%Dump{kind: kind} = dump) when kind in ~w(sales filed_gstr1) do
    invoices = Dumps.union_invoices(dump.org_id, dump.client_id, dump.period, "sales")
    {:ok, client} = Clients.get_client(dump.org_id, dump.client_id)
    directory = active_hsn_directory()
    Nila.Gst.Sales.TaxpayerChecks.enqueue(dump.org_id, invoices)

    workings =
      Workings.materialize(
        invoices,
        [],
        Gstr1.production_header(client.gstin, dump.period),
        ledger_issues(dump),
        compliance:
          maybe_put_directory(
            %{taxpayers: Nila.Gst.Sales.TaxpayerChecks.saved(invoices)},
            directory
          )
      )

    issues = Enum.map(workings.issues, &Map.delete(&1, "status"))

    {:ok, sales_month} =
      Months.upsert(%{
        org_id: dump.org_id,
        client_id: dump.client_id,
        period: dump.period,
        state: "worked",
        invoices: workings.invoices,
        derived_gstr1: workings.derived,
        issues: issues,
        hsn_master_release_id: release_id(directory),
        filed_gstr1: Dumps.filed_gstr1(dump.org_id, dump.client_id, dump.period),
        summary: %{"invoice_count" => length(invoices), "issue_count" => length(issues)}
      })

    if kind == "sales" do
      Signoffs.invalidate_gstr3b_in_transaction(sales_month, dump.brought_in_by_id)
    end

    :ok
  end

  defp active_hsn_directory do
    case Directory.active() do
      {:ok, directory} -> directory
      {:error, :not_found} -> nil
    end
  end

  defp release_id(nil), do: nil
  defp release_id(directory), do: directory.release.id

  defp maybe_put_directory(compliance, nil), do: compliance
  defp maybe_put_directory(compliance, directory), do: Map.put(compliance, :directory, directory)

  defp ledger_issues(dump) do
    unaccounted =
      dump.org_id
      |> Dumps.unaccounted_pages(dump.client_id, dump.period, "sales")
      |> Enum.map(fn %{"source" => source, "pages" => pages} ->
        %{
          "invoice" => nil,
          "code" => "pages_unaccounted",
          "level" => Issues.level_for("pages_unaccounted"),
          "message" =>
            "pages #{Enum.join(pages, ", ")} of #{source} produced no invoice. Open the " <>
              "original and confirm no bill was missed.",
          "fields" => ["doc_issue"]
        }
      end)

    evidence =
      dump.org_id
      |> Dumps.evidence_gaps(dump.client_id, dump.period, "sales")
      |> Enum.map(fn %{"source" => source} ->
        %{
          "invoice" => nil,
          "code" => "evidence_unavailable",
          "level" => Issues.level_for("evidence_unavailable"),
          "message" =>
            "#{source} was read, but its pages could not be rendered, so no scanned bill " <>
              "shows beside these invoices. Check them against the original before signing.",
          "fields" => ["doc_issue"]
        }
      end)

    unaccounted ++ evidence
  end
end
