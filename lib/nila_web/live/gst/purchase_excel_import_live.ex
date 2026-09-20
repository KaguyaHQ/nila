defmodule NilaWeb.Gst.PurchaseExcelImportLive do
  use NilaWeb, :live_view
  alias Nila.Accounts.Policy
  alias Nila.Gst.Purchase.Excel
  alias Nila.Gst.Purchase.Excel.Import
  alias Nila.Gst.Sales.Excel.Workbook

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _, socket) do
    with true <- Policy.can?(socket.assigns.current_scope, :edit_records),
         {:ok, client} <-
           Nila.Clients.get_client(socket.assigns.current_scope.current_org.id, client_id),
         {:ok, _} <- Date.from_iso8601(period <> "-01") do
      {:ok,
       socket
       |> assign(
         page_title: "Import purchase Excel",
         client: client,
         period: period,
         workbook: nil,
         bytes: nil,
         filename: nil,
         sheet: nil,
         header: 1,
         preview: nil,
         excluded: [],
         error: nil,
         selection_form: to_form(%{}, as: :selection),
         mapping_form: to_form(%{}, as: :columns),
         fields: Excel.fields()
       )
       |> allow_upload(:excel,
         accept: ~w(.xlsx),
         max_entries: 1,
         max_file_size: Workbook.max_bytes()
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You cannot import purchases for this client.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  @impl true
  def handle_event("validate-upload", _, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :excel, ref)}

  def handle_event("read", _, socket) do
    results =
      consume_uploaded_entries(socket, :excel, fn %{path: path}, entry ->
        {:ok, {File.read!(path), entry.client_name}}
      end)

    case results do
      [{bytes, filename}] ->
        case Workbook.read(bytes) do
          {:ok, %{sheets: [_ | _]} = workbook} ->
            sheet =
              Enum.find(workbook.sheets, &(not &1.hidden? and &1.rows != [])) ||
                hd(workbook.sheets)

            {:noreply,
             socket
             |> assign(workbook: workbook, bytes: bytes, filename: filename, error: nil)
             |> select_sheet(sheet)}

          _ ->
            {:noreply,
             assign(
               socket,
               :error,
               "Could not read this XLSX. Use an unencrypted workbook with up to 20 sheets, 5,000 data rows per sheet and 100 columns."
             )}
        end

      _ ->
        {:noreply, assign(socket, :error, "Choose an Excel file first.")}
    end
  end

  def handle_event("select", %{"selection" => params}, socket) do
    sheet = Enum.find(socket.assigns.workbook.sheets, &(&1.name == params["sheet"]))

    cond do
      is_nil(sheet) ->
        {:noreply, socket}

      sheet.name != socket.assigns.sheet.name ->
        {:noreply, select_sheet(socket, sheet)}

      true ->
        header = integer(params["header"])
        row = Enum.find(sheet.rows, &(&1.row == header))

        if row do
          {:noreply,
           socket
           |> assign(
             header: header,
             preview: nil,
             excluded: Excel.subtotal_rows(sheet, header),
             selection_form: to_form(params, as: :selection),
             mapping_form: column_form(Excel.mapping(row))
           )}
        else
          {:noreply, assign(socket, :error, "Choose a populated header row.")}
        end
    end
  end

  def handle_event("map", %{"columns" => mapping}, socket) do
    {:noreply,
     assign(socket, mapping_form: to_form(mapping, as: :columns), preview: nil, error: nil)}
  end

  def handle_event("edit-mapping", _, socket),
    do: {:noreply, assign(socket, preview: nil, error: nil)}

  def handle_event("preview", %{"columns" => mapping}, socket) do
    socket = assign(socket, :mapping_form, to_form(mapping, as: :columns))
    {:noreply, build_preview(socket)}
  end

  def handle_event("exclusions", %{"rows" => params}, socket) do
    excluded =
      params
      |> Enum.filter(fn {_, value} -> value == "true" end)
      |> Enum.map(fn {row, _} -> integer(row) end)

    reviewing? = not is_nil(socket.assigns.preview)
    socket = assign(socket, excluded: excluded, preview: nil)
    {:noreply, if(reviewing?, do: build_preview(socket), else: socket)}
  end

  def handle_event("save", _, %{assigns: %{preview: %{errors: [], invoices: [_ | _]}}} = socket) do
    a = socket.assigns

    selection = %{
      sheet: a.sheet.name,
      header: a.header,
      mapping: canonical_mapping(a.mapping_form.params),
      excluded: a.excluded
    }

    case Import.save(a.current_scope, a.client.id, a.period, a.bytes, a.filename, selection) do
      {:ok, _dump} ->
        {:noreply,
         socket
         |> put_flash(:info, "Excel imported. Preparing the purchase reconciliation.")
         |> push_navigate(to: ~p"/gst/#{a.client.id}/#{a.period}/purchases")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_text(reason))}
    end
  end

  def handle_event("save", _, socket),
    do:
      {:noreply,
       assign(socket, :error, "Check the mapping and fix the listed rows before importing.")}

  defp select_sheet(socket, sheet) do
    suggestion = Excel.suggest(sheet)

    socket
    |> assign(
      sheet: sheet,
      header: suggestion.header,
      preview: nil,
      excluded: Excel.subtotal_rows(sheet, suggestion.header),
      selection_form:
        to_form(%{"sheet" => sheet.name, "header" => suggestion.header}, as: :selection),
      mapping_form: column_form(suggestion.mapping)
    )
  end

  defp build_preview(socket) do
    case mapping_problems(socket.assigns.mapping_form.params) do
      [] -> preview_mapped_columns(socket)
      problems -> assign(socket, preview: nil, error: Enum.join(problems, " "))
    end
  end

  defp preview_mapped_columns(socket) do
    a = socket.assigns

    case Excel.preview(
           a.workbook,
           a.sheet.name,
           a.header,
           canonical_mapping(a.mapping_form.params),
           a.excluded,
           a.client,
           a.period
         ) do
      {:ok, preview} -> assign(socket, preview: preview, error: nil)
      {:error, message} -> assign(socket, preview: nil, error: message)
    end
  end

  defp column_form(mapping) do
    to_form(Map.new(mapping, fn {field, column} -> {column, field} end), as: :columns)
  end

  defp canonical_mapping(columns) do
    columns
    |> Enum.reject(fn {_, field} -> field in [nil, ""] end)
    |> Map.new(fn {column, field} -> {field, column} end)
  end

  defp mapping_problems(columns) do
    labels = Map.new(Excel.fields())
    selected = columns |> Map.values() |> Enum.reject(&(&1 in [nil, ""]))
    missing = for field <- Excel.required_fields(), field not in selected, do: labels[field]

    missing =
      if Enum.any?(~w(cgst_amount sgst_amount igst_amount), &(&1 in selected)),
        do: missing,
        else: missing ++ ["CGST, SGST or IGST amount"]

    duplicates =
      for {field, count} <- Enum.frequencies(selected),
          count > 1,
          do: "#{labels[field] || field} is selected for more than one column."

    if missing == [],
      do: duplicates,
      else: ["Choose columns for: #{Enum.join(missing, ", ")}." | duplicates]
  end

  defp mapping_rows(%{sheet: nil}), do: []

  defp mapping_rows(assigns) do
    header = Enum.find(assigns.sheet.rows, &(&1.row == assigns.header))
    dates = Excel.mapping(header || %{cells: %{}})

    rows =
      Enum.filter(
        assigns.sheet.rows,
        &(&1.row > assigns.header and &1.row not in assigns.excluded)
      )

    for {_, column} <- Excel.columns(assigns.sheet, assigns.header) do
      samples =
        rows
        |> Stream.map(& &1.cells[column])
        |> Stream.reject(&(&1 in [nil, ""]))
        |> Stream.uniq()
        |> Enum.take(3)
        |> Enum.map(&Excel.source_display(&1, column, dates, assigns.workbook.date1904?))

      label = Excel.display(header.cells[column])
      %{column: column, label: if(label == "", do: "No header", else: label), samples: samples}
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(_), do: "Could not import this workbook. Nothing was imported."

  defp money(value),
    do: Nila.Formatters.format_money_with_paise(Nila.Gst.Money.paise(value), prefix: "")

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:mapping_rows, mapping_rows(assigns))
      |> assign(:mapping_problems, mapping_problems(assigns.mapping_form.params))
      |> assign(:field_options, [
        {"Leave out", ""} | Enum.map(assigns.fields, fn {key, label} -> {label, key} end)
      ])

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_client={@client}>
      <div id="purchase-excel-page" class="space-y-block mx-auto w-full max-w-[1400px]">
        <.page_header title="Import purchase Excel" eyebrow={@client.name <> " / " <> @period}>
          <:actions>
            <.button
              variant="soft"
              href={~p"/gst/purchases-template.xlsx"}
              id="purchase-excel-template"
            >Download template</.button>
            <.button variant="ghost" navigate={~p"/gst/#{@client.id}/#{@period}/purchases"}>Back to purchases</.button>
          </:actions>
          Import ordinary taxable purchase invoices. Credit notes, imports, exempt purchases and reverse charge need a separate path.
        </.page_header>

        <div :if={@error} id="purchase-excel-error">
          <.callout kind="error">{@error}</.callout>
        </div>

        <.form
          :if={is_nil(@workbook)}
          for={to_form(%{})}
          id="purchase-excel-upload"
          phx-change="validate-upload"
          phx-submit="read"
          class="space-y-block"
        >
          <.file_drop
            id="purchase-excel-file"
            upload={@uploads.excel}
            label="Purchase Excel"
            hint="XLSX · up to 5 MB"
            on_cancel="cancel-upload"
          />
          <.button id="purchase-excel-read" type="submit" phx-disable-with="Reading…">Read workbook</.button>
        </.form>

        <div :if={@workbook} class="space-y-section">
          <p class="text-ui">
            {@filename} · Import one sheet at a time. Other sheets remain untouched.
          </p>

          <.form
            for={@selection_form}
            id="purchase-excel-selection"
            phx-change="select"
            class="gap-block grid grid-cols-2"
          >
            <.input
              field={@selection_form[:sheet]}
              type="select"
              label="Sheet"
              options={
                Enum.map(
                  @workbook.sheets,
                  &{&1.name <> if(&1.hidden?, do: " (hidden)", else: ""), &1.name}
                )
              }
            />
            <.input
              field={@selection_form[:header]}
              type="select"
              label="Header row"
              options={Enum.map(@sheet.rows, &{"Row #{&1.row}", &1.row})}
            />
          </.form>

          <.form
            :if={is_nil(@preview)}
            for={@mapping_form}
            id="purchase-excel-mapping"
            phx-change="map"
            phx-submit="preview"
            class="space-y-block"
          >
            <h2 class="text-h4">Match columns</h2>

            <p class="text-ink-muted text-ui">
              Check each suggested match against the sample values. Columns set to “Leave out” will not be imported.
            </p>

            <div id="purchase-excel-mapping-needs" aria-live="polite" class="space-y-related">
              <p :for={problem <- @mapping_problems} class="text-error text-ui">{problem}</p>
            </div>

            <.data_table
              id="purchase-excel-column-mapping"
              rows={@mapping_rows}
              row_id={&"purchase-excel-column-#{&1.column}"}
              mode="review"
            >
              <:col :let={row} label="Your column" row_header class="w-1/4">
                <p>{row.label}</p>

                <.context_text>Column {row.column}</.context_text>
              </:col>

              <:col :let={row} label="Sample values" class="w-1/3">
                <div class="space-y-related">
                  <p :for={value <- row.samples} class="wrap-break-word">{value}</p>

                  <p :if={row.samples == []} class="text-ink-muted">No values in included rows</p>
                </div>
              </:col>

              <:col :let={row} label="Nila field">
                <.input
                  field={@mapping_form[row.column]}
                  type="select"
                  aria-label={"Nila field for column #{row.column}: #{row.label}"}
                  options={@field_options}
                />
              </:col>
            </.data_table>

            <.button id="purchase-excel-preview" type="submit" disabled={@mapping_problems != []}>Check import</.button>
          </.form>

          <.form
            for={to_form(%{}, as: :rows)}
            id="purchase-excel-exclusions"
            phx-change="exclusions"
            class="space-y-block"
          >
            <h2 class="text-h4">Rows to leave out</h2>

            <p class="text-ink-muted text-ui">
              Rows labelled Total or Subtotal are selected below. Confirm these exclusions before importing.
            </p>

            <div class="max-h-64 overflow-y-auto">
              <.input
                :for={row <- Enum.filter(@sheet.rows, &(&1.row > @header))}
                type="checkbox"
                name={"rows[#{row.row}]"}
                id={"purchase-excel-exclude-#{row.row}"}
                checked={row.row in @excluded}
                label={"Row #{row.row}: " <> (row.cells |> Enum.sort_by(fn {col, _} -> Workbook.column_index(col) end) |> Enum.take(4) |> Enum.map(fn {col, value} -> Excel.source_display(value, col, canonical_mapping(@mapping_form.params), @workbook.date1904?) end) |> Enum.reject(&(&1 == "")) |> Enum.join(" · "))}
              />
            </div>
          </.form>

          <section :if={@preview} id="purchase-excel-review" class="space-y-block">
            <div class="gap-block flex items-center justify-between">
              <h2 class="text-h4">Check before importing</h2>

              <.button id="purchase-excel-edit-mapping" variant="ghost" phx-click="edit-mapping">Edit columns</.button>
            </div>

            <p id="purchase-excel-summary" class="text-ui">
              {count_label(length(@preview.invoices), "invoice")} · {count_label(
                @preview.row_count,
                "source row"
              )} · {count_label(length(@preview.excluded), "row")} left out
            </p>

            <p id="purchase-excel-totals" class="text-ui">
              Included rows: taxable ₹{money(@preview.totals["taxable_value"])} · CGST ₹{money(
                @preview.totals["cgst_amount"]
              )} · SGST ₹{money(@preview.totals["sgst_amount"])} · IGST ₹{money(
                @preview.totals["igst_amount"]
              )}
            </p>

            <p :if={@preview.other_sheets != []} class="text-ui">
              Sheets not imported: {Enum.join(@preview.other_sheets, ", ")}
            </p>

            <.data_table
              :if={@preview.controls != []}
              id="purchase-excel-controls"
              rows={@preview.controls}
              mode="scan"
            >
              <:col :let={control} label="Source total" row_header>
                Row {control.row} · {control.label}
              </:col>

              <:col :let={control} label="In the sheet" align="right">{money(control.source)}</:col>

              <:col :let={control} label="Included rows" align="right">
                {money(control.included)}
              </:col>

              <:col :let={control} label="Difference" align="right">{money(control.difference)}</:col>
            </.data_table>

            <.data_table
              :if={@preview.errors != []}
              id="purchase-excel-problems"
              rows={@preview.errors}
              mode="review"
            >
              <:col :let={error} label="Row" row_header>{error.row}</:col>

              <:col :let={error} label="Needs attention">{error.message}</:col>
            </.data_table>

            <.data_table id="purchase-excel-invoices" rows={@preview.invoices} mode="scan">
              <:col :let={invoice} label="Invoice" row_header>{invoice["invoice_number"]}</:col>

              <:col :let={invoice} label="Date">{invoice["invoice_date"]}</:col>

              <:col :let={invoice} label="Supplier">{invoice["vendor_name"]}</:col>

              <:col :let={invoice} label="Taxable value" align="right">
                {money(invoice["taxable_paise"] / 100)}
              </:col>

              <:col :let={invoice} label="Tax" align="right">
                {money(Enum.sum(Map.values(invoice["tax_paise"])) / 100)}
              </:col>

              <:col :let={invoice} label="Source rows">
                {Enum.join(invoice["source_rows"], ", ")}
              </:col>
            </.data_table>

            <p class="text-ink-muted text-ui">
              Check these totals against your sheet. GST checks continue in purchase review after import. Nothing is approved or filed here.
            </p>

            <.button
              id="purchase-excel-save"
              phx-click="save"
              disabled={@preview.errors != [] or @preview.invoices == []}
              phx-disable-with="Importing…"
            >Confirm and import purchases</.button>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
