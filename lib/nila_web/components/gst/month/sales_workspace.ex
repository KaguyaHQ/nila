defmodule NilaWeb.Components.Gst.Month.SalesWorkspace do
  use NilaWeb, :html

  @moduledoc "The filing-period index and drill-downs for Sales and GSTR-1."

  alias Nila.Formatters
  alias Nila.Gst.Filing.{Calendar, WinmanGstr1}
  alias Nila.Gst.Sales.{Gstr1, Values}
  alias NilaWeb.Components.Gst.Month.{Helpers, Workings}

  @schedule_order [
    {"b2b", "B2B — sales to registered persons"},
    {"b2cl", "B2CL — inter-state consumers"},
    {"exp", "Exports"},
    {"sez", "SEZ / deemed exports"},
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
      |> assign(:base, base)
      |> assign(:schedule_rows, schedule_rows(assigns, review_ids, hsn, documents, base))
      |> assign(:period_label, Formatters.period_label(assigns.period))
      |> assign(:deadline, deadline(assigns.period))
      |> assign(:previous_period, shift_period(assigns.period, -1))
      |> assign(:next_period, shift_period(assigns.period, 1))

    ~H"""
    <section id="sales-period-workspace" class="pb-section mx-auto max-w-6xl">
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
          <.overview
            client={@client}
            period={@period}
            base={@base}
            invoices={@invoices}
            active_invoices={@active_invoices}
            totals={@totals}
            review={@review}
            review_count={@review_count}
            schedule_rows={@schedule_rows}
            dumps={@dumps}
            readiness={@readiness}
          />
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
        <% view when view in [:b2b, :b2cl, :b2cs, :cdnr] -> %>
          <.schedule_view
            view={view}
            client={@client}
            period={@period}
            base={@base}
            invoices={@active_invoices}
            review_ids={@review_ids}
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

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :period_label, :string, required: true
  attr :deadline, :string, required: true
  attr :previous_period, :string, required: true
  attr :next_period, :string, required: true
  attr :base, :string, required: true
  attr :view, :atom, required: true

  defp period_header(assigns) do
    ~H"""
    <header class="border-rule flex flex-wrap items-end justify-between gap-4 border-b pb-4">
      <div class="min-w-0">
        <p class="text-ink-subtle text-label font-semibold uppercase">
          {@client.name} · Sales &amp; GSTR-1
        </p>

        <div class="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h1 class="font-display text-base-content text-h3 font-normal">{@period_label}</h1>

          <p class="text-ink-muted text-ui">{@deadline}</p>
        </div>
      </div>

      <nav aria-label="Filing period" class="flex items-center gap-1">
        <.button
          navigate={~p"/gst/#{@client.id}/#{@previous_period}/sales"}
          variant="ghost"
          size="xs"
          aria-label="Previous filing period"
        >
          <.icon name="hero-chevron-left-mini" class="size-4" />
        </.button>

        <span class="text-base-content text-ui min-w-24 text-center font-semibold">{@period_label}</span>
        <.button
          navigate={~p"/gst/#{@client.id}/#{@next_period}/sales"}
          variant="ghost"
          size="xs"
          aria-label="Next filing period"
        >
          <.icon name="hero-chevron-right-mini" class="size-4" />
        </.button>
      </nav>
    </header>
    """
  end

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :base, :string, required: true
  attr :invoices, :list, required: true
  attr :active_invoices, :list, required: true
  attr :totals, :any, default: nil
  attr :review, :any, required: true
  attr :review_count, :integer, required: true
  attr :schedule_rows, :list, required: true
  attr :dumps, :list, required: true
  attr :readiness, :map, required: true

  defp overview(assigns) do
    first_review = List.first(assigns.review.needs_you)
    upload_files = Enum.sum(Enum.map(assigns.dumps, &length(&1.file_keys)))

    workflow_stage =
      workflow_stage(assigns.readiness, length(assigns.active_invoices), assigns.review_count)

    assigns =
      assign(assigns,
        first_review: first_review,
        upload_files: upload_files,
        workflow_stage: workflow_stage
      )

    ~H"""
    <div class="pt-block space-y-block">
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="space-y-related">
          <p class="text-base-content text-ui tabular-nums">
            {count_label(length(@active_invoices), "invoice")} · {Helpers.rupees(
              @totals && @totals.taxable
            )} taxable · {Helpers.rupees(@totals && @totals.tax)} output tax
          </p>

          <p
            :if={@workflow_stage != :export}
            id="sales-period-status"
            class="text-ink-muted text-ui"
          >
            <%= if @workflow_stage == :collect do %>
              Add invoices to prepare the GST working.
            <% else %>
              GST working needs review.
            <% end %>
          </p>
        </div>

        <div id="sales-period-primary-action" class="flex flex-wrap items-center gap-2">
          <.button
            :if={@workflow_stage == :collect}
            navigate={~p"/gst/upload?client_id=#{@client.id}&period=#{@period}&kind=sales"}
            variant="primary"
            size="sm"
          >
            Bring in invoices
          </.button>

          <.button
            :if={@workflow_stage == :review and @first_review}
            patch={
              review_path(
                @client,
                @period,
                @first_review.source_id,
                :needs_you,
                @base <> "/invoices"
              )
            }
            variant="primary"
            size="sm"
          >
            Review {@review_count}
          </.button>

          <.download_button
            :if={@workflow_stage == :export}
            id="sales-period-primary-download"
            href={~p"/gstr1/#{@client.id}/#{@period}/workings.xlsx"}
            variant="primary"
            size="sm"
          >
            Download GST working
          </.download_button>

          <.text_link
            :if={@workflow_stage == :export}
            id="sales-period-export-link"
            href="#sales-period-export"
            class="inline-flex items-center gap-1"
          >
            Winman / JSON exports <.icon name="hero-arrow-down-mini" class="size-4" />
          </.text_link>
        </div>
      </div>

      <.sales_section
        base={@base}
        invoice_count={length(@invoices)}
        taxable={@totals && @totals.taxable}
        review_count={@review_count}
        dumps={@dumps}
        upload_files={@upload_files}
      /> <.schedules_section rows={@schedule_rows} />
      <.export_section
        client={@client}
        period={@period}
        base={@base}
        invoice_count={length(@active_invoices)}
        readiness={@readiness}
        review_count={@review_count}
      />
    </div>
    """
  end

  attr :base, :string, required: true
  attr :invoice_count, :integer, required: true
  attr :taxable, :any, default: nil
  attr :review_count, :integer, required: true
  attr :dumps, :list, required: true
  attr :upload_files, :integer, required: true

  defp sales_section(assigns) do
    sales_row = %{
      id: "invoices",
      label: "Sales invoices",
      count: assigns.invoice_count,
      taxable: Helpers.rupees(assigns.taxable),
      status: review_status(assigns.invoice_count, assigns.review_count),
      variant: if(assigns.review_count > 0, do: "warning", else: "success"),
      path: assigns.base <> "/invoices"
    }

    assigns = assign(assigns, :rows, [sales_row])

    ~H"""
    <section class="space-y-related">
      <.data_table
        id="sales-period-sources"
        rows={@rows}
        row_id={&"sales-period-sources-#{&1.id}"}
        row_navigate={& &1.path}
        row_label={fn row -> row.path && "Open #{row.label}" end}
        mode="scan"
        min_width="min-w-[720px]"
      >
        <:col :let={row} label="Sales" row_header class="w-[42%]">
          <span class="font-medium">{row.label}</span>
        </:col>

        <:col :let={row} label="Invoices" class="w-[16%]">{row.count}</:col>

        <:col :let={row} label="Taxable value" align="right" class="w-[20%]">{row.taxable}</:col>

        <:col :let={row} label="Status" class="w-[18%]">
          <.badge variant={row.variant}>{row.status}</.badge>
        </:col>

        <:col :let={row} label="" align="right" class="w-[4%]">
          <.icon :if={row.path} name="hero-chevron-right-mini" class="text-ink-faint size-4" />
        </:col>
      </.data_table>

      <.text_link
        id="sales-period-uploads-link"
        navigate={@base <> "/uploads"}
        class="inline-flex items-center gap-1"
      >
        Uploads · {count_label(length(@dumps), "batch", "batches")} · {count_label(
          @upload_files,
          "file"
        )} <.icon name="hero-chevron-right-mini" class="size-4" />
      </.text_link>
    </section>
    """
  end

  attr :rows, :list, required: true

  defp schedules_section(assigns) do
    ~H"""
    <section class="space-y-related">
      <p id="sales-period-return-heading" class="text-ink-subtle text-label font-semibold uppercase">
        GSTR-1
      </p>

      <.data_table
        id="sales-period-return"
        rows={@rows}
        row_id={&"sales-period-return-#{&1.id}"}
        row_navigate={& &1.path}
        row_label={fn row -> row.path && "Open #{row.label}" end}
        mode="scan"
        min_width="min-w-[720px]"
      >
        <:col :let={row} label="Section" row_header class="w-[42%]">
          <span class={["font-medium", is_nil(row.path) && "text-ink-muted"]}>{row.label}</span>
        </:col>

        <:col :let={row} label="Entries" class="w-[16%]">{row.count}</:col>

        <:col :let={row} label="Taxable value" align="right" class="w-[20%]">{row.value || "—"}</:col>

        <:col :let={row} label="Status" class="w-[18%]">
          <.badge variant={row.variant}>{row.status}</.badge>
        </:col>

        <:col :let={row} label="" align="right" class="w-[4%]">
          <.icon :if={row.path} name="hero-chevron-right-mini" class="text-ink-faint size-4" />
        </:col>
      </.data_table>
    </section>
    """
  end

  attr :client, :map, required: true
  attr :base, :string, required: true
  attr :period, :string, required: true
  attr :invoice_count, :integer, required: true
  attr :readiness, :map, required: true
  attr :review_count, :integer, required: true

  defp export_section(assigns) do
    ~H"""
    <section id="sales-period-export" class="space-y-related scroll-mt-4">
      <p class="text-ink-subtle text-label font-semibold uppercase">Export</p>

      <.data_table
        id="sales-period-handoff"
        rows={[%{id: "workings"}, %{id: "winman"}, %{id: "json"}]}
        row_id={&"sales-period-handoff-#{&1.id}"}
        mode="scan"
        min_width="min-w-[720px]"
      >
        <:col :let={row} label="Output" row_header>
          <span :if={row.id == "workings"}>GST sales working</span>
          <span :if={row.id == "winman"}>Winman GSTR-1</span>
          <span :if={row.id == "json"}>GSTR-1 JSON</span>
        </:col>

        <:col :let={row} label="Format">
          <%= case row.id do %>
            <% "workings" -> %>
              XLSX
            <% "winman" -> %>
              XLSM
            <% "json" -> %>
              JSON
          <% end %>
        </:col>

        <:col :let={row} label="Download">
          <.download_button
            :if={row.id == "workings" and @invoice_count > 0 and @review_count == 0}
            id="sales-period-handoff-download-workings"
            href={~p"/gstr1/#{@client.id}/#{@period}/workings.xlsx"}
            variant="outline"
            size="xs"
          >
            Download
          </.download_button>

          <span
            :if={row.id == "workings" and @invoice_count == 0}
            class="text-ink-muted text-ui"
          >
            Unavailable — add invoices
          </span>

          <span
            :if={row.id == "workings" and @invoice_count > 0 and @review_count > 0}
            class="text-ui text-warning"
          >
            Unavailable — <.text_link navigate={@base <> "/invoices"}>review invoices</.text_link>
          </span>

          <.export_action
            :if={row.id == "winman"}
            kind={:winman}
            client={@client}
            base={@base}
            period={@period}
            readiness={@readiness}
            review_count={@review_count}
          />
          <.export_action
            :if={row.id == "json"}
            kind={:json}
            client={@client}
            base={@base}
            period={@period}
            readiness={@readiness}
            review_count={@review_count}
          />
        </:col>
      </.data_table>
    </section>
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
      variant="outline"
      size="xs"
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
      variant="outline"
      size="xs"
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
    <div class="pt-section space-y-section">
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

  defp schedule_view(assigns) do
    key = Atom.to_string(assigns.view)
    label = @schedule_order |> Enum.find_value(fn {row_key, label} -> row_key == key && label end)
    rows = Enum.filter(assigns.invoices, &(Gstr1.filing_table(&1) == key))
    assigns = assign(assigns, label: label, rows: invoice_rows(rows, assigns.review_ids, assigns))

    ~H"""
    <div class="pt-section space-y-section">
      <.detail_heading
        base={@base}
        title={@label}
        copy="The invoices contributing to this GSTR-1 schedule."
      /> <.invoice_table id={"sales-period-schedule-#{@view}"} rows={@rows} />
    </div>
    """
  end

  attr :base, :string, required: true
  attr :rows, :list, required: true

  defp documents_view(assigns) do
    ~H"""
    <div class="pt-section space-y-section">
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

        <h2 class="text-base-content text-h4 mt-3 font-semibold">{@title}</h2>

        <p class="text-ink-muted text-ui mt-1">{@copy}</p>
      </div>
    </header>
    """
  end

  defp schedule_rows(assigns, review_ids, hsn, documents, base) do
    counts = Enum.frequencies_by(assigns.active_invoices, &Gstr1.filing_table/1)

    statutory =
      Enum.map(@schedule_order, fn {key, label} ->
        count = counts[key] || 0
        unresolved = count_unresolved(assigns.active_invoices, review_ids, key)
        supported = key in ~w(b2b b2cl b2cs cdnr)

        %{
          id: key,
          label: label,
          count: if(count == 0, do: "—", else: count_label(count, document_noun(key))),
          value: schedule_value(assigns.derived, key, count),
          status: schedule_status(count, unresolved, supported),
          variant: schedule_variant(count, unresolved, supported),
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

  defp invoice_rows(invoices, review_ids, assigns) do
    Enum.map(invoices, fn invoice ->
      totals = Gstr1.extracted_totals(invoice)
      needs_review = MapSet.member?(review_ids, invoice["id"])

      %{
        id: invoice["id"] || invoice["invoice_number"],
        number: invoice["invoice_number"] || "—",
        date: format_display_date(invoice["invoice_date"]),
        buyer: invoice["buyer_name"] || "—",
        treatment: invoice |> Gstr1.filing_table() |> treatment_label(),
        taxable: Helpers.rupees(totals.taxable),
        tax: Helpers.rupees(totals.tax),
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
        &(Gstr1.filing_table(&1) == key and MapSet.member?(review_ids, &1["id"]))
      )

  defp schedule_value(_derived, _key, 0), do: nil
  defp schedule_value(nil, _key, _count), do: nil

  defp schedule_value(derived, key, _count),
    do: Helpers.rupees(section_totals(derived, key).taxable)

  defp schedule_status(0, _unresolved, _supported), do: "No entries"

  defp schedule_status(_count, unresolved, _supported) when unresolved > 0, do: "Draft"

  defp schedule_status(_count, _unresolved, true), do: "Prepared"
  defp schedule_status(_count, _unresolved, false), do: "Not supported"

  defp schedule_variant(0, _unresolved, _supported), do: "neutral"
  defp schedule_variant(_count, unresolved, _supported) when unresolved > 0, do: "warning"
  defp schedule_variant(_count, _unresolved, true), do: "success"
  defp schedule_variant(_count, _unresolved, false), do: "error"

  defp section_totals(derived, section) do
    Enum.reduce(~w(b2b b2cs b2cl cdnr), derived, fn key, acc ->
      if key == section, do: acc, else: Map.put(acc, key, [])
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

  defp review_status(0, _review_count), do: "No invoices"
  defp review_status(_invoice_count, 0), do: "Ready"
  defp review_status(_invoice_count, _review_count), do: "Needs review"

  defp workflow_stage(_readiness, 0, _review_count), do: :collect
  defp workflow_stage(_readiness, _invoice_count, review_count) when review_count > 0, do: :review

  defp workflow_stage(%{state: state}, _invoice_count, _review_count)
       when state in [:ready, :awaiting_senior, :approved, :filed],
       do: :export

  defp workflow_stage(_readiness, _invoice_count, _review_count), do: :review

  defp document_noun("cdnr"), do: "note"
  defp document_noun(_key), do: "invoice"

  defp treatment_label("b2b"), do: "B2B"
  defp treatment_label("b2cl"), do: "B2CL"
  defp treatment_label("b2cs"), do: "B2C"
  defp treatment_label("cdnr"), do: "Credit/debit note"
  defp treatment_label(_table), do: "Held out"

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

  defp count_label(count, noun, plural \\ nil)
  defp count_label(1, noun, _plural), do: "1 #{noun}"
  defp count_label(count, noun, nil), do: "#{count} #{noun}s"
  defp count_label(count, _noun, plural), do: "#{count} #{plural}"
end
