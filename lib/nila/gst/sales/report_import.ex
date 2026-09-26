defmodule Nila.Gst.Sales.ReportImport do
  @moduledoc "Imports a sales report through the existing source ledger and GST month."
  alias Nila.{Clients, Repo, Storage}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}

  alias Nila.Gst.Sales.{
    Excel.Workbook,
    Excel.CsvWorkbook,
    Excel.KpnRegister,
    Excel.ReportPacket,
    Excel.ReturnReport,
    Excel.StandardSections,
    Excel.UltinoRegister,
    ReturnSources
  }

  import Ecto.Query
  alias Nila.Gst.Sales.Review.{Resolution, Resolutions}

  def review(month) do
    events = Enum.map(Resolutions.list(month.id), &%{"verb" => &1.verb, "payload" => &1.payload})

    invoices =
      Nila.Gst.Sales.Invoice.Corrections.apply_sources(
        month.org_id,
        month.client_id,
        month.invoices || []
      )

    for report <- reports(month, events) do
      evidence = Enum.filter(invoices, &(&1["return_report_dump_id"] == report["dump_id"]))

      report
      |> Nila.Gst.Sales.ReturnSuggestions.annotate()
      |> Map.put("basis", basis({report, evidence}))
    end
  end

  def tasks(month) do
    Nila.Gst.Sales.ReportReview.build(Resolutions.effective_workings(month), review(month))
  end

  def correct(scope, month, %{"sheet" => "notes"} = params) do
    Repo.transact(fn ->
      month =
        Repo.one!(from m in Nila.Gst.Sales.Month, where: m.id == ^month.id, lock: "FOR UPDATE")

      with true <-
             Policy.can?(scope, :edit_records) and scope.current_org.id == month.org_id and
               is_nil(month.filed_at),
           task when not is_nil(task) <-
             Enum.find(
               tasks(month),
               &(&1["kind"] == "notes" and &1["dump_id"] == params["dump_id"] and
                   &1["source_ids"] == params["source_ids"])
             ),
           true <- task["basis"] == params["basis"],
           values when is_map(values) <- params["values"],
           true <- Enum.sort(Map.keys(values)) == Enum.sort(task["fields"]),
           {:ok, _} <-
             Enum.reduce_while(task["source_ids"], {:ok, nil}, fn id, _ ->
               case Nila.Gst.Sales.Invoice.Corrections.save_in_transaction(
                      month.org_id,
                      month.client_id,
                      to_string(params["dump_id"]),
                      id,
                      values,
                      scope.user.id
                    ) do
                 {:ok, result} -> {:cont, {:ok, result}}
                 error -> {:halt, error}
               end
             end) do
        {:ok, review(month)}
      else
        _ ->
          {:error,
           "These notes changed or the correction is invalid. Refresh and review them again."}
      end
    end)
  end

  def correct(scope, month, params) do
    Repo.transact(fn ->
      month =
        Repo.one!(from m in Nila.Gst.Sales.Month, where: m.id == ^month.id, lock: "FOR UPDATE")

      with true <-
             Policy.can?(scope, :edit_records) and scope.current_org.id == month.org_id and
               is_nil(month.filed_at),
           report when not is_nil(report) <-
             Enum.find(review(month), &(&1["dump_id"] == params["dump_id"])),
           true <- report["basis"] == params["basis"],
           :ok <- validate_edit(report, params),
           {:ok, _} <-
             %Resolution{
               org_id: month.org_id,
               sales_month_id: month.id,
               decided_by_id: scope.user.id
             }
             |> Resolution.changeset(%{
               verb: "correct_return_row",
               target:
                 "report:#{params["dump_id"]}:#{params["source_filename"]}:#{params["sheet"]}:#{params["row"]}",
               payload: Map.take(params, ~w(dump_id source_filename sheet row values basis))
             })
             |> Repo.insert() do
        Resolutions.reopen_review(month)
        Nila.Gst.Filing.Signoffs.invalidate_gstr3b_in_transaction(month, scope.user.id)
        {:ok, review(month)}
      else
        _ ->
          {:error,
           "This report changed or the correction is invalid. Refresh and review it again."}
      end
    end)
  end

  defp validate_edit(report, %{
         "sheet" => "report",
         "values" => %{"b2cs_before_notes" => value} = values
       })
       when is_boolean(value) and map_size(values) == 1 do
    if Enum.any?(report["rows"], &(&1["section"] == "cdnur")), do: :ok, else: :error
  end

  defp validate_edit(report, %{"sheet" => sheet, "row" => number, "values" => values} = params)
       when is_map(values) do
    matches =
      Enum.filter(report["rows"], &row_match?(&1, sheet, number, params["source_filename"]))

    row = if length(matches) == 1, do: hd(matches)

    allowed =
      case row && row["section"] do
        "doc_issue" -> ~w(doc_num from to totnum cancel net_issue)
        "b2cs" -> ~w(pos rate txval iamt camt samt csamt)
        s when s in ~w(hsn_b2b hsn_b2c) -> ~w(hsn_sc desc uqc qty rate txval iamt camt samt csamt)
        _ -> []
      end

    valid =
      Enum.all?(values, fn {key, value} ->
        key in allowed and
          if(key in ~w(nature from to pos hsn_sc desc uqc),
            do: is_binary(value) and byte_size(value) <= 200,
            else: is_number(value) and abs(value) < 1.0e12
          ) and ReturnSources.valid_summary_field?(row["section"], key, value)
      end)

    if row && map_size(values) > 0 && valid, do: :ok, else: :error
  end

  defp validate_edit(_, _), do: :error

  defp row_match?(row, sheet, number, filename) do
    row["sheet"] == sheet and row["row"] == number and
      (is_nil(filename) or row["source_filename"] == filename)
  end

  defp basis(report),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(report)) |> Base.encode16(case: :lower)

  def save(scope, client_id, period, bytes, filename) do
    with true <- Policy.can?(scope, :edit_records),
         true <-
           is_binary(filename) and String.downcase(Path.extname(filename)) in ~w(.xls .xlsx .csv),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, workbook} <- read_workbook(bytes, filename),
         workbook <- put_source_filename(workbook, filename),
         {:ok, report} <- parse_report(workbook, client, period) do
      persist(scope, client, period, [%{bytes: bytes, filename: filename}], report)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def save_many(scope, client_id, period, files) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, {files, workbook}} <- ReportPacket.prepare(files),
         {:ok, report} <- StandardSections.parse(workbook, client, period) do
      persist(scope, client, period, files, report)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def discard(scope, client_id, period, dump_id) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {id, ""} when id > 0 <- Integer.parse(to_string(dump_id)) do
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [73_013, client.id])

        month =
          Repo.one(
            from m in Nila.Gst.Sales.Month,
              where:
                m.org_id == ^scope.current_org.id and m.client_id == ^client.id and
                  m.period == ^period,
              lock: "FOR UPDATE"
          )

        dump =
          Repo.one(
            from d in Dump,
              where:
                d.id == ^id and d.org_id == ^scope.current_org.id and
                  d.client_id == ^client.id and d.period == ^period and
                  d.kind == "sales",
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(dump) or is_nil(dump.meta["return_report"]) or dump.status == "discarded" ->
            {:error, :not_found}

          not is_nil(month) and not is_nil(month.filed_at) ->
            {:error, "This month is filed. Reopen it before removing the sales report."}

          DumpWorker.wall_state(dump) != :open ->
            {:error, "This month is signed or filed. Reopen it before removing the sales report."}

          true ->
            meta =
              dump.meta
              |> Map.put("discarded_by_id", scope.user.id)
              |> Map.put("discarded_at", DateTime.utc_now() |> DateTime.to_iso8601())

            dump = dump |> Dump.changeset(%{status: "discarded", meta: meta}) |> Repo.update!()

            :ok =
              Nila.Gst.Sales.Derivation.refresh_in_transaction(%{
                dump
                | brought_in_by_id: scope.user.id
              })

            {:ok, dump}
        end
      end)
    else
      false -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp read_workbook(bytes, filename) do
    if String.downcase(Path.extname(filename)) == ".csv",
      do: CsvWorkbook.read(bytes),
      else: Workbook.read(bytes)
  end

  defp put_source_filename(workbook, filename) do
    %{
      workbook
      | sheets: Enum.map(workbook.sheets, &Map.put(&1, :source_filename, Path.basename(filename)))
    }
  end

  defp parse_report(workbook, client, period) do
    cond do
      StandardSections.matches?(workbook) -> StandardSections.parse(workbook, client, period)
      UltinoRegister.matches?(workbook) -> UltinoRegister.parse(workbook, client, period)
      KpnRegister.matches?(workbook) -> KpnRegister.parse(workbook, client, period)
      true -> ReturnReport.parse(workbook, client, period)
    end
  end

  defp persist(scope, client, period, files, report) do
    files = Enum.map(files, &Map.put(&1, :filename, Path.basename(&1.filename)))

    manifest =
      Enum.map(files, &%{"filename" => &1.filename, "sha256" => ReportPacket.digest(&1.bytes)})

    filename = hd(files).filename

    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [73_013, client.id])

      Repo.one(
        from m in Nila.Gst.Sales.Month,
          where:
            m.org_id == ^scope.current_org.id and m.client_id == ^client.id and
              m.period == ^period,
          lock: "FOR UPDATE"
      )

      existing = Dumps.list(scope.current_org.id, client.id, period)

      wall =
        DumpWorker.wall_state(%Dump{
          org_id: scope.current_org.id,
          client_id: client.id,
          period: period,
          kind: "sales"
        })

      cond do
        wall != :open ->
          {:error, "This month is signed or filed. Reopen it before importing."}

        Enum.any?(existing, &(&1.status != "discarded" and &1.meta["return_report"])) ->
          {:error,
           "This month already has a sales report. Review that upload before importing another; summaries could overlap."}

        true ->
          filename = Path.basename(filename)

          stored =
            Enum.reduce_while(files, {:ok, []}, fn file, {:ok, keys} ->
              key =
                "orgs/#{scope.current_org.id}/clients/#{client.id}/#{period}/excel/#{Ecto.UUID.generate()}#{Path.extname(file.filename)}"

              case Storage.put(key, file.bytes) do
                {:ok, _} -> {:cont, {:ok, [key | keys]}}
                error -> {:halt, error}
              end
            end)

          with {:ok, reversed_keys} <- stored,
               {:ok, dump} <-
                 Dumps.record(
                   %{
                     org_id: scope.current_org.id,
                     client_id: client.id,
                     brought_in_by_id: scope.user.id
                   },
                   %{
                     period: period,
                     kind: "sales",
                     status: "extracted",
                     file_keys: Enum.reverse(reversed_keys),
                     meta: %{
                       "sales_batch" => true,
                       "excel_import" => true,
                       "original_name" => filename,
                       "excel_sha256" => hd(manifest)["sha256"],
                       "file_manifest" => manifest,
                       "return_report" => Map.delete(report, "invoices")
                     }
                   }
                 ) do
            invoices =
              (report["invoices"] || ReturnReport.invoices(report, client))
              |> Enum.map(fn invoice ->
                invoice
                |> Map.update!("id", &"d#{dump.id}_#{&1}")
                |> Map.put(
                  "source_filename",
                  invoice["source_filename"] || source_filename(report, invoice) || filename
                )
                |> Map.put("return_report_dump_id", dump.id)
              end)

            dump = dump |> Dump.changeset(%{invoices: invoices}) |> Repo.update!()

            :ok = Nila.Gst.Sales.Derivation.refresh_in_transaction(dump)
            {:ok, dump}
          end
      end
    end)
  end

  defp source_filename(report, invoice) do
    source_ids = invoice["source_ids"] || []

    Enum.find_value(report["rows"] || [], fn row ->
      if row["id"] in source_ids or
           (row["sheet"] == invoice["source_sheet"] and row["row"] == invoice["source_row"]),
         do: row["source_filename"]
    end)
  end

  def reports(month, resolutions) do
    reports =
      Dumps.effective(month.org_id, month.client_id, month.period, "sales")
      |> ReturnSources.from_dumps()
      |> Enum.map(fn report ->
        Map.update!(report, "rows", fn rows ->
          Enum.map(rows, &Map.put(&1, "source_values", &1["values"]))
        end)
      end)

    Enum.reduce(resolutions, reports, fn resolution, current ->
      if resolution["verb"] == "correct_return_row" do
        payload = resolution["payload"]

        Enum.map(current, fn report ->
          if report["dump_id"] == payload["dump_id"] do
            if payload["sheet"] == "report" do
              Map.put(report, "b2cs_before_notes", payload["values"]["b2cs_before_notes"])
            else
              Map.update!(report, "rows", fn rows ->
                Enum.map(rows, fn row ->
                  if row_match?(row, payload["sheet"], payload["row"], payload["source_filename"]) and
                       (payload["source_filename"] ||
                          Enum.count(rows, &row_match?(&1, payload["sheet"], payload["row"], nil)) ==
                            1),
                     do: Map.update!(row, "values", &Map.merge(&1, payload["values"])),
                     else: row
                end)
              end)
            end
          else
            report
          end
        end)
      else
        current
      end
    end)
  end
end
