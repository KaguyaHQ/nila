defmodule NilaWeb.Gst.PurchaseImportWorkspace do
  @moduledoc "Stateless, evidence-bound purchase XLSX preview and confirmation."
  alias Nila.Gst.Purchase.Excel
  alias Nila.Gst.Purchase.Excel.Import
  alias Nila.Gst.Sales.Excel.Workbook
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace
  @salt "purchase-excel-preview-v1"
  @max_age 3600

  def editable(scope, client, period) do
    if DumpWorker.wall_state(%Dump{
         org_id: scope.current_org.id,
         client_id: client.id,
         period: period,
         kind: "purchase"
       }) == :open, do: :ok, else: {:error, :signed_off}
  end

  def file(%Plug.Upload{path: path, filename: filename}) do
    with true <- String.downcase(Path.extname(filename)) == ".xlsx",
         {:ok, %{size: size}} when size > 0 and size <= 5_000_000 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, workbook} <- Workbook.read(bytes),
         true <- workbook.sheets != [] do
      {:ok, %{bytes: bytes, filename: Path.basename(filename), workbook: workbook}}
    else
      _ -> {:error, :invalid_file}
    end
  end

  def file(_), do: {:error, :invalid_file}

  def read(file, params) do
    with {:ok, selection} <- decode(params["selection"], %{}),
         sheet when not is_nil(sheet) <- choose_sheet(file.workbook, selection["sheet"]),
         header = selection["header"] || Excel.suggest(sheet).header,
         true <- is_integer(header),
         row when not is_nil(row) <- Enum.find(sheet.rows, &(&1.row == header)) do
      mapping = Excel.mapping(row)
      excluded = Excel.subtotal_rows(sheet, header)
      candidates = Enum.filter(sheet.rows, &(&1.row > header and &1.row not in excluded))

      {:ok,
       %{
         filename: file.filename,
         max_bytes: Workbook.max_bytes(),
         sheets:
           Enum.map(
             file.workbook.sheets,
             &%{name: &1.name, hidden: &1.hidden?, row_count: length(&1.rows)}
           ),
         fields:
           Enum.map(Excel.fields(), fn {id, label} ->
             %{id: id, label: label, required: id in Excel.required_fields()}
           end),
         selection: %{sheet: sheet.name, header: header, mapping: mapping, excluded: excluded},
         header_rows:
           Enum.map(
             sheet.rows,
             &%{row: &1.row, label: "Row #{&1.row}: " <> summary(&1, mapping, file.workbook)}
           ),
         columns:
           Enum.map(Excel.columns(sheet, header), fn {_label, column} ->
             samples =
               candidates
               |> Stream.map(& &1.cells[column])
               |> Stream.reject(&(&1 in [nil, ""]))
               |> Stream.uniq()
               |> Enum.take(3)
               |> Enum.map(&Excel.source_display(&1, column, mapping, file.workbook.date1904?))

             %{id: column, label: Excel.display(row.cells[column]), samples: samples}
           end),
         rows:
           sheet.rows
           |> Enum.filter(&(&1.row > header))
           |> Enum.map(&%{row: &1.row, summary: summary(&1, mapping, file.workbook)}),
         limits:
           "XLSX up to 5 MB, 20 sheets, 5,000 data rows per sheet and 100 columns. Import one sheet at a time."
       }}
    else
      _ -> {:error, :invalid_selection}
    end
  end

  def preview(scope, client, period, file, params) do
    with {:ok, raw} <- decode(params["selection"], nil),
         {:ok, selection} <- selection(raw),
         {:ok, preview} <-
           Excel.preview(
             file.workbook,
             selection.sheet,
             selection.header,
             selection.mapping,
             selection.excluded,
             client,
             period
           ) do
      valid = preview.errors == [] and preview.invoices != []

      token =
        if valid,
          do:
            Phoenix.Token.sign(NilaWeb.Endpoint, @salt, %{
              org: scope.current_org.id,
              user: scope.user.id,
              client: client.id,
              period: period,
              digest: digest(file.bytes),
              selection: selection
            })

      {:ok,
       %{
         token: token,
         can_import: valid,
         invoice_count: length(preview.invoices),
         row_count: preview.row_count,
         excluded: Enum.map(preview.excluded, & &1.row),
         other_sheets: preview.other_sheets,
         totals:
           Enum.map(
             [
               {"taxable_value", "Taxable value"},
               {"cgst_amount", "CGST"},
               {"sgst_amount", "SGST"},
               {"igst_amount", "IGST"}
             ],
             fn {key, label} -> %{label: label, amount: money(preview.totals[key])} end
           ),
         controls:
           Enum.map(
             preview.controls,
             &%{
               row: &1.row,
               label: &1.label,
               source: money(&1.source),
               included: money(&1.included),
               difference: money(&1.difference)
             }
           ),
         errors: preview.errors,
         invoices: Enum.map(preview.invoices, &invoice/1)
       }}
    else
      error -> error
    end
  end

  def commit(scope, client, period, file, token) when is_binary(token) do
    with {:ok, payload} <- Phoenix.Token.verify(NilaWeb.Endpoint, @salt, token, max_age: @max_age),
         true <-
           payload.org == scope.current_org.id and payload.user == scope.user.id and
             payload.client == client.id and payload.period == period and
             payload.digest == digest(file.bytes),
         {:ok, dump} <-
           Import.save(scope, client.id, period, file.bytes, file.filename, payload.selection) do
      {:ok,
       %{
         ok: true,
         upload_id: dump.id,
         state: dump.status,
         uploads_path: base(client, period) <> "/uploads?upload=#{dump.id}",
         register_path: "/app" <> base(client, period) <> "/register"
       }}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, :invalid_token}
    end
  end

  def commit(_, _, _, _, _), do: {:error, :invalid_token}

  def history(scope, client, period, params) do
    dumps =
      Dumps.list(scope.current_org.id, client.id, period)
      |> Enum.filter(&(&1.kind == "purchase"))
      |> Enum.reverse()

    selected = Enum.find(dumps, &(to_string(&1.id) == params["upload"]))

    if params["upload"] && is_nil(selected) do
      {:error, :not_found}
    else
      can_import =
        Nila.Accounts.Policy.can?(scope, :edit_records) and editable(scope, client, period) == :ok

      {:ok,
       %{
         client: %{id: client.id, name: client.name, gstin: client.gstin},
         period: period,
         can_import: can_import,
         lock_reason:
           if(not can_import,
             do: "Import requires an editable month and permission to change records."
           ),
         processing: Enum.any?(dumps, &(&1.status in ~w(received extracting))),
         uploads:
           Enum.map(dumps, fn dump ->
             %{
               id: dump.id,
               name: name(dump),
               created_at: dump.inserted_at,
               state: dump.status,
               label: label(dump.status),
               invoice_count: length(dump.invoices),
               sheet: dump.meta["excel_sheet"],
               excluded_rows: dump.meta["excel_excluded_rows"] || [],
               other_sheets: dump.meta["excel_other_sheets"] || [],
               originals:
                 dump.file_keys
                 |> Enum.with_index()
                 |> Enum.map(fn {_, index} ->
                   %{
                     label:
                       if(length(dump.file_keys) == 1,
                         do: "Download original",
                         else: "Download original #{index + 1}"
                       ),
                     url: "/gst/#{client.id}/#{period}/original/#{dump.id}/#{index}"
                   }
                 end),
               error:
                 if(dump.status == "failed",
                   do: "Processing failed. Open purchase review to check this upload."
                 ),
               resolve_url:
                 if(dump.status in ~w(failed held after_filing needs_confirmation),
                   do: "/app" <> base(client, period)
                 )
             }
           end),
         selected:
           if(selected,
             do: %{
               id: selected.id,
               name: name(selected),
               label: label(selected.status),
               invoices: Enum.map(selected.invoices, &Map.put(invoice(&1), :id, &1["id"]))
             }
           ),
         register_path: "/app" <> base(client, period) <> "/register",
         import_path: base(client, period) <> "/import-excel"
       }}
    end
  end

  defp selection(%{
         "sheet" => sheet,
         "header" => header,
         "mapping" => mapping,
         "excluded" => excluded
       })
       when is_binary(sheet) and is_integer(header) and header > 0 and is_map(mapping) and
              is_list(excluded) do
    fields = Enum.map(Excel.fields(), &elem(&1, 0))

    if map_size(mapping) <= length(fields) and
         Enum.all?(mapping, fn {field, column} -> field in fields and is_binary(column) end) and
         length(excluded) <= 5001 and Enum.all?(excluded, &(is_integer(&1) and &1 > header)),
       do:
         {:ok,
          %{
            sheet: sheet,
            header: header,
            mapping: Map.reject(mapping, fn {_, column} -> column == "" end),
            excluded: Enum.uniq(excluded)
          }},
       else: {:error, :invalid_selection}
  end

  defp selection(_), do: {:error, :invalid_selection}
  defp decode(nil, default) when is_map(default), do: {:ok, default}

  defp decode(value, _) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _ -> {:error, :invalid_selection}
    end
  end

  defp decode(_, _), do: {:error, :invalid_selection}

  defp choose_sheet(workbook, nil),
    do:
      Enum.find(workbook.sheets, &(not &1.hidden? and &1.rows != [])) ||
        List.first(workbook.sheets)

  defp choose_sheet(workbook, name), do: Enum.find(workbook.sheets, &(&1.name == name))

  defp summary(row, mapping, workbook),
    do:
      row.cells
      |> Enum.sort_by(fn {col, _} -> Workbook.column_index(col) end)
      |> Enum.take(4)
      |> Enum.map(fn {col, value} ->
        Excel.source_display(value, col, mapping, workbook.date1904?)
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" · ")

  defp invoice(row),
    do: %{
      number: row["invoice_number"],
      date: row["invoice_date"],
      vendor: row["vendor_name"],
      gstin: row["vendor_gstin"],
      taxable: Workspace.money(row["taxable_paise"] || 0),
      tax: Workspace.money(Workspace.source_tax(row)),
      source_rows: row["source_rows"] || []
    }

  defp money(value), do: Workspace.money(Nila.Gst.Money.paise(value || 0))
  defp digest(bytes), do: :crypto.hash(:sha256, bytes)
  defp base(client, period), do: "/gst/#{client.id}/#{period}/purchases"

  defp name(dump),
    do: dump.meta["original_name"] || Enum.map_join(dump.file_keys, ", ", &Path.basename/1)

  defp label("extracted"), do: "Imported"
  defp label("received"), do: "Waiting to process"
  defp label("extracting"), do: "Processing"
  defp label("failed"), do: "Processing failed"
  defp label("held"), do: "Held after sign-off"
  defp label("after_filing"), do: "Arrived after filing"
  defp label("needs_confirmation"), do: "Needs confirmation"
  defp label("discarded"), do: "Discarded"
  defp label(_), do: "Needs attention"
end
