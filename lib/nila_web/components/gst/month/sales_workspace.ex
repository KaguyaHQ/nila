defmodule NilaWeb.Components.Gst.Month.SalesWorkspace do
  use NilaWeb, :html

  @moduledoc "The filing-period index and drill-downs for Sales and GSTR-1."

  alias Nila.Formatters
  alias Nila.Gst.Filing.{Calendar, WinmanGstr1}
  alias Nila.Gst.Sales.{Gstr1, Invoice, Values}
  alias NilaWeb.Components.Gst.Month.{Helpers, Workings}

  @gstr1_table_order [
    {"b2b", "B2B — sales to registered persons"},
    {"b2cl", "B2CL — inter-state consumers"},
    {"exp", "Exports"},
    {"sez", "SEZ supplies"},
    {"b2cs", "B2C (others)"},
    {"exempt", "Exempt / non-taxable supplies"},
    {"cdnr", "Credit notes / debit notes"},
    {"advances", "Advances received / adjusted"},
    {"ecommerce", "Supplies through e-commerce operator"}
  ]

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :view, :atom, required: true
  attr :invoices, :list, required: true
  attr :active_invoices, :list, required: true
  attr :register_rows, :list, required: true
  attr :register_form, :any, required: true
  attr :register_filter, :atom, required: true
  attr :issues_by_invoice, :map, required: true
  attr :review, :any, required: true
  attr :derived, :any, default: nil
  attr :readiness, :map, required: true
  attr :dumps, :list, default: []
  attr :expanded_nodes, :any, default: MapSet.new()
  attr :rippled, :any, default: MapSet.new()
  attr :ripple_seq, :integer, default: 0
  slot :source

  def workspace(assigns) do
    totals = if(assigns.derived, do: Values.filed_totals(assigns.derived), else: nil)
    hsn = if(assigns.derived, do: Gstr1.hsn_summary(assigns.active_invoices), else: [])
    documents = document_rows(assigns.derived)
    review_ids = MapSet.new(assigns.review.needs_you, & &1.source_id)
    base = base_path(assigns.client, assigns.period)

    assigns =
      assigns
      |> assign(:totals, totals)
      |> assign(:hsn, hsn)
      |> assign(:documents, documents)
      |> assign(:review_ids, review_ids)
      |> assign(:review_count, MapSet.size(review_ids))
      |> assign(
        :exports_available?,
        assigns.active_invoices != [] and assigns.readiness.state != :absent and
          MapSet.size(review_ids) == 0
      )
      |> assign(:base, base)
      |> assign(:gstr1_table_rows, gstr1_table_rows(assigns, review_ids, hsn, documents, base))
      |> assign(:period_label, full_period_label(assigns.period))
      |> assign(:deadline, deadline(assigns.period))
      |> assign(:previous_period, shift_period(assigns.period, -1))
      |> assign(:next_period, shift_period(assigns.period, 1))

    ~H"""
    <section
      id="sales-period-workspace"
      class="pb-section space-y-block mx-auto w-full max-w-[1400px]"
    >
      <.period_header
        client={@client}
        period={@period}
        period_label={@period_label}
        deadline={@deadline}
        previous_period={@previous_period}
        next_period={@next_period}
        base={@base}
        view={@view}
      />
      <%= case @view do %>
        <% :overview -> %>
          <.overview {assigns} />
        <% :invoices -> %>
          <.invoices_view
            client={@client}
            period={@period}
            base={@base}
            rows={@register_rows}
            form={@register_form}
            filter={@register_filter}
            issues_by_invoice={@issues_by_invoice}
            review_ids={@review_ids}
            review={@review}
          />
        <% :uploads -> %>
          <.detail_heading
            base={@base}
            title="Uploads"
            copy="The batches contributing sales documents to this filing period."
          /> {render_slot(@source)}
        <% view when view in [:b2b, :b2cl, :b2cs, :cdnr, :exp, :sez] -> %>
          <.gstr1_table_view
            view={view}
            client={@client}
            period={@period}
            base={@base}
            invoices={@active_invoices}
            review_ids={@review_ids}
            derived={@derived}
          />
        <% :hsn -> %>
          <.detail_heading
            base={@base}
            title="HSN-wise summary"
            copy="The invoice lines contributing to Table 12."
          />
          <Workings.hsn_summary
            :if={@derived}
            derived={@derived}
            invoices={@active_invoices}
            expanded={@expanded_nodes}
            rippled={@rippled}
            ripple_seq={@ripple_seq}
          />
        <% :documents -> %>
          <.documents_view base={@base} rows={@documents} />
      <% end %>
    </section>
    """
  end

  defp overview(assigns) do
    assigns =
      assign(assigns,
        stage:
          workflow_stage(assigns.readiness, length(assigns.active_invoices), assigns.review_count),
        first_review: List.first(assigns.review.needs_you),
        upload_files: Enum.sum(Enum.map(assigns.dumps, &length(&1.file_keys)))
      )

    ~H"""
    <div id="sales-period-overview" class="space-y-block">
      <.card padding="none">
        <.card_header title="Sales invoices">
          <p id="sales-period-status" class="text-ink-muted text-ui mt-1">
            <%= case @stage do %>
              <% :collect -> %>
                Add invoices to prepare this month's GST working.
              <% :review -> %>
                Review the GST working before exporting.
              <% :export -> %>
                Your GST working is available to download.
            <% end %>
          </p>

          <:actions>
            <div id="sales-period-primary-action">
              <.button
                :if={@stage == :collect}
                navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}&kind=sales"}
                variant="primary"
                size="sm"
              >Bring in invoices</.button>
              <.button
                :if={@stage == :review}
                navigate={
                  if(@first_review,
                    do:
                      review_path(
                        @client,
                        @period,
                        @first_review.source_id,
                        :needs_you,
                        @base <> "/invoices"
                      ),
                    else: @base <> "/invoices"
                  )
                }
                variant="primary"
                size="sm"
              >Review invoices</.button>
              <.download_button
                :if={@stage == :export}
                id="sales-period-primary-download"
                href={~p"/gstr1/#{@client.id}/#{@period}/workings.xlsx"}
                variant="primary"
                size="sm"
              >Download GST working</.download_button>
            </div>
          </:actions>
        </.card_header>

        <div class="text-ui flex flex-wrap items-center gap-x-6 gap-y-2 px-6 py-4 tabular-nums">
          <span><span class="font-semibold">{length(@active_invoices)}</span>
          <span class="text-ink-muted">invoices in working</span></span>
          <span class="border-rule border-l pl-6"><span class="font-semibold">{if @totals,
            do: Helpers.rupees(@totals.taxable),
            else: "—"}</span> <span class="text-ink-muted">taxable</span></span>
          <span class="border-rule border-l pl-6"><span class="font-semibold">{if @totals,
            do: Helpers.rupees(@totals.tax),
            else: "—"}</span> <span class="text-ink-muted">output tax</span></span>
        </div>

        <div class="border-rule text-ui flex flex-wrap justify-between gap-2 border-t px-6 py-3">
          <.text_link navigate={@base <> "/invoices"}>View sales register
          <.icon name="hero-chevron-right-mini" class="inline size-4" /></.text_link>
          <.text_link id="sales-period-uploads-link" navigate={@base <> "/uploads"}>Uploads · {count_label(
            length(@dumps),
            "batch"
          )} · {count_label(@upload_files, "file")}</.text_link>
        </div>
      </.card>

      <div class="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_280px]">
        <.gstr1_tables_section rows={@gstr1_table_rows} />
        <.card padding="none" id="sales-period-export">
          <.card_header title="Exports" />
          <p
            :if={@readiness.state == :absent or (@active_invoices == [] and @review_count == 0)}
            class="text-ink-muted text-ui px-6 pt-4"
          >
            Add invoices to make exports available.
          </p>

          <p
            :if={@readiness.state != :absent and @review_count > 0}
            class="text-ink-muted text-ui px-6 pt-4"
          >
            <.text_link navigate={@base <> "/invoices"}>Review invoices</.text_link> before exporting.
          </p>

          <div class="divide-rule divide-y px-6">
            <div id="sales-period-handoff-workings" class="space-y-3 py-4">
              <p class="text-ui">GST sales working <span class="text-ink-muted">· XLSX</span></p>

              <.download_button
                :if={@exports_available?}
                id="sales-period-handoff-download-workings"
                href={~p"/gstr1/#{@client.id}/#{@period}/workings.xlsx"}
                variant="soft"
                size="sm"
              >Download</.download_button>
            </div>

            <div
              :for={{kind, label} <- [{:winman, "Winman GSTR-1 · XLSM"}, {:json, "GSTR-1 · JSON"}]}
              id={"sales-period-handoff-#{kind}"}
              class="space-y-3 py-4"
            >
              <p class="text-ui">{label}</p>

              <.export_action
                :if={@exports_available?}
                kind={kind}
                client={@client}
                base={@base}
                period={@period}
                readiness={@readiness}
                review_count={@review_count}
              />
            </div>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :period_label, :string, required: true
  attr :deadline, :string, required: true
  attr :previous_period, :string, required: true
  attr :next_period, :string, required: true
  attr :base, :string, required: true
  attr :view, :atom, required: true

  defp period_header(assigns) do
    assigns =
      assign(
        assigns,
        :can_go_forward?,
        assigns.period < Elixir.Calendar.strftime(Date.utc_today(), "%Y-%m")
      )

    ~H"""
    <.page_header eyebrow={@client.name <> " / Sales & GSTR-1"} title={@period_label}>
      <:title_actions>
        <nav aria-label="Filing period" class="flex items-center gap-1">
          <.button
            navigate={~p"/gst/#{@client.id}/#{@previous_period}/sales"}
            variant="ghost"
            size="sm"
            id="previous-filing-period"
            title="Previous month ([)"
            aria-label="Previous filing period"
          >
            <.icon name="hero-chevron-left-mini" class="size-4" />
          </.button>

          <.button
            navigate={if @can_go_forward?, do: ~p"/gst/#{@client.id}/#{@next_period}/sales"}
            disabled={not @can_go_forward?}
            variant="ghost"
            size="sm"
            id="next-filing-period"
            title="Next month (])"
            aria-label="Next filing period"
          >
            <.icon name="hero-chevron-right-mini" class="size-4" />
          </.button>
        </nav>
      </:title_actions>

      <:actions>
        <div class="gap-related flex items-center">
          <span class="text-ink-muted text-ui">{@deadline}</span>
        </div>
      </:actions>
    </.page_header>
    """
  end

  attr :rows, :list, required: true

  defp gstr1_tables_section(assigns) do
    ~H"""
    <.card padding="none">
      <.card_header id="sales-period-return-heading" title="GSTR-1 tables" />
      <div class="px-4 pt-2 pb-3">
        <.data_table
          id="sales-period-return"
          surface="ghost"
          rows={@rows}
          row_id={&"sales-period-return-#{&1.id}"}
          row_navigate={& &1.path}
          row_label={fn row -> row.path && "Open #{row.label}" end}
          mode="scan"
          min_width="min-w-[720px]"
        >
          <:col :let={row} key="section" label="Section" row_header>
            <span class={["text-base-content", row.path && "font-medium"]}>{row.label}</span>
          </:col>

          <:col :let={row} key="entries" label="Entries" align="right" class="w-[100px]">
            <span class="whitespace-nowrap">{row.count}</span>
          </:col>

          <:col :let={row} key="taxable" label="Taxable value" align="right" class="w-[180px]">
            {row.value || "—"}
          </:col>

          <:col :let={row} key="status" label="Status" class="w-[160px]">
            <span class={[
              row.status == "No entries" && "text-ink-muted",
              row.variant == "warning" && "text-warning",
              row.variant == "error" && "text-error"
            ]}>
              <span
                :if={row.status == "Prepared"}
                aria-hidden="true"
                class="bg-success mr-1.5 inline-block size-1.5 rounded-full"
              /> {row.status}
            </span>
          </:col>

          <:col :let={row} label="" align="right" class="w-[40px]">
            <.icon :if={row.path} name="hero-chevron-right-mini" class="text-ink-faint size-4" />
          </:col>
        </.data_table>
      </div>
    </.card>
    """
  end

  attr :kind, :atom, values: [:winman, :json], required: true
  attr :client, :map, required: true
  attr :base, :string, required: true
  attr :period, :string, required: true
  attr :readiness, :map, required: true
  attr :review_count, :integer, required: true

  defp export_action(assigns) do
    ~H"""
    <span :if={@readiness.state == :absent} class="text-ink-muted text-ui">
      Unavailable — add invoices
    </span>

    <span :if={@readiness.state == :provisional or @review_count > 0} class="text-ui text-warning">
      Unavailable — <.text_link navigate={@base <> "/invoices"}>review invoices</.text_link>
    </span>

    <.download_button
      :if={
        @kind == :winman and @readiness.state != :absent and @review_count == 0 and
          WinmanGstr1.supported_period?(@period)
      }
      id="sales-period-handoff-download-winman"
      href={~p"/gstr1/#{@client.id}/#{@period}/winman-b2b.xlsm"}
      variant="soft"
      size="sm"
    >
      Download
    </.download_button>

    <span
      :if={
        @kind == :winman and @readiness.state != :absent and @review_count == 0 and
          not WinmanGstr1.supported_period?(@period)
      }
      class="text-ink-muted text-ui"
    >
      Unavailable for this period
    </span>

    <.download_button
      :if={@kind == :json and @readiness.state != :absent and @review_count == 0}
      id="sales-period-handoff-download-json"
      href={~p"/gstr1/#{@client.id}/#{@period}/return.json"}
      variant="soft"
      size="sm"
    >
      Download
    </.download_button>
    """
  end

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :base, :string, required: true
  attr :rows, :list, required: true
  attr :form, :any, required: true
  attr :filter, :atom, required: true
  attr :issues_by_invoice, :map, required: true
  attr :review_ids, :any, required: true
  attr :review, :any, required: true

  defp invoices_view(assigns) do
    assigns =
      assign(assigns, :invoice_rows, invoice_rows(assigns.rows, assigns.review_ids, assigns))

    ~H"""
    <div class="space-y-block">
      <.detail_heading
        base={@base}
        title="Sales invoices"
        copy="The consolidated sales population for this filing period."
      />
      <div class="flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
        <.form
          for={@form}
          id="sales-period-register-search"
          phx-change="search-sales-register"
          class="w-full max-w-sm"
        >
          <.input
            field={@form[:query]}
            type="search"
            label="Search sales invoices"
            placeholder="Invoice, buyer or GSTIN"
          />
        </.form>

        <.segmented_control
          id="sales-period-register-filters"
          items={[{:review_cases, "Needs review"}, {:no_open_checks, "Ready"}, {:all, "All"}]}
          selected={@filter}
          on_change="filter-sales-register"
          value_name="filter"
        />
      </div>
      <.invoice_table id="sales-period-invoices" rows={@invoice_rows} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true

  defp invoice_table(assigns) do
    ~H"""
    <.data_table
      id={@id}
      rows={@rows}
      row_id={&"#{@id}-#{&1.id}"}
      row_navigate={& &1.path}
      row_label={&"Review invoice #{&1.number}"}
      mode="worklist"
      min_width="min-w-[900px]"
    >
      <:empty>No invoices match this view.</:empty>

      <:col :let={row} label="Invoice" row_header>
        <span class="font-mono font-medium">{row.number}</span>
      </:col>

      <:col :let={row} label="Date"><span class="whitespace-nowrap">{row.date}</span></:col>

      <:col :let={row} label="Buyer">
        <span class="block max-w-64 truncate" title={row.buyer}>{row.buyer}</span>
      </:col>

      <:col :let={row} label="Treatment">{row.treatment}</:col>

      <:col :let={row} label="Taxable" align="right">{row.taxable}</:col>

      <:col :let={row} label="GST" align="right">{row.tax}</:col>

      <:col :let={row} label="Status">
        <.badge variant={row.variant}>{row.status}</.badge>
      </:col>

      <:col label="" align="right">
        <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4" />
      </:col>
    </.data_table>
    """
  end

  attr :view, :atom, required: true
  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :base, :string, required: true
  attr :invoices, :list, required: true
  attr :review_ids, :any, required: true

  attr :derived, :any, required: true

  defp gstr1_table_view(assigns) do
    key = Atom.to_string(assigns.view)

    label =
      @gstr1_table_order |> Enum.find_value(fn {row_key, label} -> row_key == key && label end)

    rows = Enum.filter(assigns.invoices, &(workspace_table(&1) == key))

    assigns =
      assign(assigns,
        label: label,
        rows: invoice_rows(rows, assigns.review_ids, assigns, assigns.derived)
      )

    ~H"""
    <div class="space-y-block">
      <.detail_heading
        base={@base}
        title={@label}
        copy="The invoices contributing to this GSTR-1 table."
      /> <.invoice_table id={"sales-period-gstr1-table-#{@view}"} rows={@rows} />
    </div>
    """
  end

  attr :base, :string, required: true
  attr :rows, :list, required: true

  defp documents_view(assigns) do
    ~H"""
    <div class="space-y-block">
      <.detail_heading
        base={@base}
        title="Documents issued"
        copy="The document series derived from invoices supplied to Nila."
      />
      <.data_table
        id="sales-period-documents"
        rows={@rows}
        row_id={&"sales-period-document-#{&1.id}"}
        mode="scan"
      >
        <:empty>No document series to show.</:empty>

        <:col :let={row} label="Document kind" row_header>
          <span class="font-medium">{row.kind}</span>
        </:col>

        <:col :let={row} label="From"><span class="font-mono">{row.from}</span></:col>

        <:col :let={row} label="To"><span class="font-mono">{row.to}</span></:col>

        <:col :let={row} label="Total" align="right">{row.total}</:col>

        <:col :let={row} label="Cancelled" align="right">{row.cancelled}</:col>

        <:col :let={row} label="Net issued" align="right">{row.net_issued}</:col>
      </.data_table>

      <p class="text-ink-muted text-ui">
        This checks the documents Nila received; it does not prove every issued invoice was supplied.
      </p>
    </div>
    """
  end

  attr :base, :string, required: true
  attr :title, :string, required: true
  attr :copy, :string, required: true

  defp detail_heading(assigns) do
    ~H"""
    <header class="border-rule flex flex-wrap items-end justify-between gap-4 border-b pb-4">
      <div>
        <.text_link navigate={@base} class="inline-flex items-center gap-1">
          <.icon name="hero-chevron-left-mini" class="size-4" /> Period overview
        </.text_link>

        <h2 class="text-base-content text-h4 mt-3 font-medium">{@title}</h2>

        <p class="text-ink-muted text-ui mt-1">{@copy}</p>
      </div>
    </header>
    """
  end

  defp gstr1_table_rows(assigns, review_ids, hsn, documents, base) do
    counts = Enum.frequencies_by(assigns.active_invoices, &workspace_table/1)

    statutory =
      Enum.map(@gstr1_table_order, fn {key, label} ->
        count = counts[key] || 0
        unresolved = count_unresolved(assigns.active_invoices, review_ids, key)
        supported = key in ~w(b2b b2cl b2cs cdnr exp sez)

        %{
          id: key,
          label: label,
          count: if(count == 0, do: "—", else: count_label(count, document_noun(key))),
          value: gstr1_table_value(assigns.derived, key, count),
          status: gstr1_table_status(count, unresolved, supported),
          variant: gstr1_table_variant(count, unresolved, supported),
          path: if(count > 0 and supported, do: base <> "/#{key}")
        }
      end)

    appendix_state =
      if(MapSet.size(review_ids) > 0, do: {"Draft", "warning"}, else: {"Prepared", "success"})

    {appendix_status, appendix_variant} = appendix_state

    statutory ++
      [
        %{
          id: "hsn",
          label: "HSN-wise summary of outward supplies",
          count: if(hsn == [], do: "—", else: "#{length(hsn)} HSN/SAC"),
          value: assigns.derived && Helpers.rupees(Values.filed_totals(assigns.derived).taxable),
          status: if(hsn == [], do: "No entries", else: appendix_status),
          variant: if(hsn == [], do: "neutral", else: appendix_variant),
          path: if(hsn != [], do: base <> "/hsn")
        },
        %{
          id: "documents",
          label: "Documents issued",
          count:
            if(documents == [],
              do: "—",
              else: count_label(Enum.sum(Enum.map(documents, & &1.net_issued)), "document")
            ),
          value: nil,
          status: if(documents == [], do: "No entries", else: appendix_status),
          variant: if(documents == [], do: "neutral", else: appendix_variant),
          path: if(documents != [], do: base <> "/documents")
        }
      ]
  end

  defp invoice_rows(invoices, review_ids, assigns, derived \\ nil) do
    Enum.map(invoices, fn invoice ->
      totals =
        if derived, do: Values.filed(invoice, derived), else: Gstr1.extracted_totals(invoice)

      needs_review = MapSet.member?(review_ids, invoice["id"])

      %{
        id: invoice["id"] || invoice["invoice_number"],
        number: invoice["invoice_number"] || "—",
        date: format_display_date(invoice["invoice_date"]),
        buyer: invoice["buyer_name"] || "—",
        treatment: invoice_treatment(invoice),
        taxable: Helpers.rupees(totals && totals.taxable),
        tax: Helpers.rupees(totals && totals.tax),
        status: if(needs_review, do: "Needs review", else: "Ready"),
        variant: if(needs_review, do: "warning", else: "success"),
        path:
          review_path(
            assigns.client,
            assigns.period,
            invoice["id"],
            if(needs_review, do: :needs_you, else: :all),
            assigns.base <> "/invoices"
          )
      }
    end)
  end

  defp count_unresolved(invoices, review_ids, key),
    do:
      Enum.count(
        invoices,
        &(workspace_table(&1) == key and MapSet.member?(review_ids, &1["id"]))
      )

  defp gstr1_table_value(_derived, _key, 0), do: nil
  defp gstr1_table_value(nil, _key, _count), do: nil

  defp gstr1_table_value(derived, key, _count),
    do: Helpers.rupees(section_totals(derived, key).taxable)

  defp gstr1_table_status(0, _unresolved, _supported), do: "No entries"

  defp gstr1_table_status(_count, unresolved, _supported) when unresolved > 0, do: "Draft"

  defp gstr1_table_status(_count, _unresolved, true), do: "Prepared"
  defp gstr1_table_status(_count, _unresolved, false), do: "Not supported"

  defp gstr1_table_variant(0, _unresolved, _supported), do: "neutral"
  defp gstr1_table_variant(_count, unresolved, _supported) when unresolved > 0, do: "warning"
  defp gstr1_table_variant(_count, _unresolved, true), do: "success"
  defp gstr1_table_variant(_count, _unresolved, false), do: "error"

  defp section_totals(derived, section) when section in ["sez", "b2b"] do
    groups =
      for group <- derived["b2b"] || [] do
        Map.update!(
          group,
          "inv",
          &Enum.filter(&1, fn inv -> inv["inv_typ"] in ["SEWP", "SEWOP"] == (section == "sez") end)
        )
      end

    section_totals(Map.put(derived, "b2b", groups), "registered")
  end

  defp section_totals(derived, section) do
    section = if section == "registered", do: "b2b", else: section

    Enum.reduce(~w(b2b b2cs b2cl cdnr cdnur nil exp), derived, fn key, acc ->
      if key == section, do: acc, else: Map.put(acc, key, if(key == "nil", do: %{}, else: []))
    end)
    |> Values.filed_totals()
  end

  defp document_rows(nil), do: []

  defp document_rows(derived) do
    derived
    |> get_in(["doc_issue", "doc_det"])
    |> List.wrap()
    |> Enum.flat_map(fn group ->
      group
      |> Map.get("docs", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {series, index} ->
        %{
          id: "#{group["doc_num"]}-#{index}",
          kind: document_kind(group["doc_num"]),
          from: series["from"],
          to: series["to"],
          total: series["totnum"],
          cancelled: series["cancel"],
          net_issued: series["net_issue"]
        }
      end)
    end)
  end

  defp document_kind(1), do: "Tax invoices"
  defp document_kind(4), do: "Debit notes"
  defp document_kind(5), do: "Credit notes"
  defp document_kind(number), do: "Document type #{number}"

  defp workflow_stage(_readiness, 0, _review_count), do: :collect
  defp workflow_stage(_readiness, _invoice_count, review_count) when review_count > 0, do: :review

  defp workflow_stage(%{state: state}, _invoice_count, _review_count)
       when state in [:ready, :awaiting_senior, :approved, :filed],
       do: :export

  defp workflow_stage(_readiness, _invoice_count, _review_count), do: :review

  defp document_noun("cdnr"), do: "note"
  defp document_noun(_key), do: "invoice"

  defp workspace_table(invoice) do
    if Gstr1.filing_table(invoice) == "b2b" and invoice["supply_type"] == "sez",
      do: "sez",
      else: Gstr1.filing_table(invoice)
  end

  defp invoice_treatment(invoice) do
    cond do
      is_nil(Gstr1.filing_table(invoice)) ->
        "Held out"

      Invoice.reverse_charge?(invoice) ->
        "B2B · reverse charge"

      Invoice.zero_rated?(invoice) ->
        treatment_label(workspace_table(invoice)) <>
          if(Invoice.without_payment?(invoice), do: " · LUT/bond", else: " · with IGST")

      true ->
        treatment_label(workspace_table(invoice))
    end
  end

  defp treatment_label("exp"), do: "Export"
  defp treatment_label("sez"), do: "SEZ"
  defp treatment_label("b2b"), do: "B2B"
  defp treatment_label("b2cl"), do: "B2CL"
  defp treatment_label("b2cs"), do: "B2C"
  defp treatment_label("cdnr"), do: "Credit/debit note"
  defp treatment_label(_table), do: "Held out"

  defp full_period_label(period) do
    case Date.from_iso8601(period <> "-01") do
      {:ok, date} -> Elixir.Calendar.strftime(date, "%B %Y")
      _ -> Formatters.period_label(period)
    end
  end

  defp deadline(period) do
    due = period |> Calendar.due_dates() |> Map.fetch!(:gstr1)
    "GSTR-1 due #{Formatters.format_display_date(due)}"
  end

  defp shift_period(period, months) do
    [year, month] = period |> String.split("-") |> Enum.map(&String.to_integer/1)
    shifted = year * 12 + month - 1 + months

    "#{div(shifted, 12)}-#{shifted |> rem(12) |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp review_path(client, period, source_id, scope, return_to) do
    query =
      URI.encode_query(%{"item" => source_id, "scope" => scope, "return_to" => return_to})

    "/gst/#{client.id}/#{period}/review/sales?#{query}"
  end

  defp base_path(client, period), do: "/gst/#{client.id}/#{period}/sales"

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, "batch"), do: "#{count} batches"
  defp count_label(count, noun), do: "#{count} #{noun}s"
end
