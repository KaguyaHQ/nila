defmodule Nila.Gst.Purchase.Excel.Import do
  @moduledoc "Saves a confirmed spreadsheet through the existing purchase intake and Oban workflow."
  import Ecto.Query, only: [from: 2]
  alias Nila.{Clients, Repo, Storage}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias Nila.Gst.Purchase.Excel
  alias Nila.Gst.Sales.Excel.Workbook

  def save(scope, client_id, period, bytes, filename, selection) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, _} <- Date.from_iso8601(period <> "-01"),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, workbook} <- Workbook.read(bytes),
         {:ok, preview} <-
           Excel.preview(
             workbook,
             selection.sheet,
             selection.header,
             selection.mapping,
             selection.excluded,
             client,
             period
           ),
         true <- preview.errors == [] and preview.invoices != [] do
      digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      ref = Ecto.UUID.generate()
      key = "orgs/#{scope.current_org.id}/clients/#{client.id}/#{period}/excel/#{ref}.xlsx"

      Repo.transact(fn ->
        # Recheck under a client lock so two confirmations cannot add the same invoice.
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [73_014, client.id])

        existing =
          Repo.all(
            from d in Dump,
              where:
                d.org_id == ^scope.current_org.id and d.client_id == ^client.id and
                  d.kind == "purchase" and d.status != "discarded"
          )

        invoice_keys = MapSet.new(Enum.flat_map(existing, & &1.invoices), &identity/1)

        probe = %Dump{
          org_id: scope.current_org.id,
          client_id: client.id,
          period: period,
          kind: "purchase"
        }

        Repo.one(
          from m in Nila.Gst.Purchase.Month,
            where:
              m.org_id == ^probe.org_id and m.client_id == ^client.id and m.period == ^period,
            lock: "FOR UPDATE"
        )

        cond do
          DumpWorker.wall_state(probe) != :open ->
            {:error, "This purchase month is signed or filed. Reopen it before importing."}

          Enum.any?(
            existing,
            &(&1.meta["excel_sha256"] == digest and &1.meta["excel_sheet"] == selection.sheet)
          ) ->
            {:error, "This sheet has already been imported for this client."}

          Enum.any?(preview.invoices, &MapSet.member?(invoice_keys, identity(&1))) ->
            {:error,
             "An invoice with the same supplier, number and date already exists for this client. Nothing was imported."}

          true ->
            with {:ok, _} <- Storage.put(key, bytes),
                 {:ok, dump} <-
                   Dumps.record(
                     %{
                       org_id: scope.current_org.id,
                       client_id: client.id,
                       brought_in_by_id: scope.user.id
                     },
                     %{
                       period: period,
                       kind: "purchase",
                       file_keys: [key],
                       meta: %{
                         "original_name" => Path.basename(filename),
                         "excel_import" => true,
                         "excel_sha256" => digest,
                         "excel_sheet" => selection.sheet,
                         "excel_header" => selection.header,
                         "excel_mapping" => selection.mapping,
                         "excel_excluded_rows" => Enum.map(preview.excluded, & &1.row),
                         "excel_other_sheets" => preview.other_sheets
                       }
                     }
                   ) do
              invoices =
                preview.invoices
                |> Enum.with_index(1)
                |> Enum.map(fn {invoice, index} ->
                  invoice
                  |> Map.put("id", "d#{dump.id}_excel_#{index}")
                  |> Map.put("source_filename", Path.basename(filename))
                end)

              dump = dump |> Dump.changeset(%{invoices: invoices}) |> Repo.update!()
              %{dump_id: dump.id} |> DumpWorker.new() |> Oban.insert!()
              {:ok, dump}
            end
        end
      end)
    else
      false ->
        {:error, "Import is not permitted or the sheet still has errors. Nothing was imported."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp identity(invoice) do
    date =
      case invoice["invoice_date"] do
        %Date{} = date ->
          Date.to_iso8601(date)

        value ->
          case Nila.Gst.Dates.parse_date(value) do
            %Date{} = date -> Date.to_iso8601(date)
            _ -> value
          end
      end

    {invoice["vendor_gstin"],
     invoice["invoice_number"] |> to_string() |> String.trim() |> String.upcase(), date}
  end
end
