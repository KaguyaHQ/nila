defmodule NilaWeb.Gst.InvoiceReviewLive do
  use NilaWeb, :live_view

  alias NilaWeb.Gst.{InvoiceWorkbench, SalesBillReview}

  import NilaWeb.Gst.SalesBillReview,
    except: [mount: 3, handle_params: 3, handle_event: 3, handle_info: 2]

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(:selected_invoice, nil)
       |> assign(:checks_open?, false)
       |> assign(:passed_checks_open?, false)
       |> assign(:checks_about_open?, false)}

  @impl true
  def handle_params(
        %{"client_id" => client_id, "period" => period, "source_id" => source_id} = params,
        uri,
        socket
      ) do
    org_id = socket.assigns.current_scope.current_org.id
    review_batch = params["batch"]

    case InvoiceWorkbench.source_batch(org_id, client_id, period, source_id) do
      %{batch_ref: batch_ref} when is_nil(review_batch) or review_batch == batch_ref ->
        socket =
          if socket.assigns[:batch_ref] == batch_ref and
               to_string(socket.assigns.client.id) == client_id do
            socket
          else
            {:ok, socket} =
              SalesBillReview.mount(
                %{"client_id" => client_id, "batch_ref" => batch_ref},
                %{},
                socket
              )

            socket
          end

        changed_invoice? = invoice_id(socket.assigns.selected_invoice) != source_id

        socket =
          if changed_invoice?,
            do:
              socket
              |> assign(:checks_open?, false)
              |> assign(:passed_checks_open?, false)
              |> assign(:checks_about_open?, false),
            else: socket

        socket = assign(socket, :review_batch, params["batch"])

        params =
          params
          |> Map.put("item", source_id)
          |> Map.put("review", if(params["scope"] == "needs_you", do: "required"))

        {:noreply, socket} = SalesBillReview.handle_params(params, uri, socket)

        socket =
          if changed_invoice?,
            do: assign(socket, :checks_open?, gst_workbench_issues(socket.assigns) != []),
            else: socket

        {:noreply, assign(socket, :page_title, "Invoice review")}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "That invoice could not be found.")
         |> push_navigate(to: ~p"/gst/#{client_id}/#{period}/sales/invoices")}
    end
  end

  @impl true
  def handle_event("navigate-posting-review", %{"item" => source_id}, socket) do
    invoices =
      if socket.assigns.workbench_context,
        do: Enum.map(socket.assigns.workbench_context.queue, & &1.invoice),
        else: socket.assigns.packet.all_invoices

    if Enum.any?(invoices, &(invoice_id(&1) == source_id)) do
      {:noreply, push_patch(socket, to: review_path(socket, source_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("workbench-view", %{"view" => view}, socket)
      when view in ~w(invoice accounting) do
    {:noreply,
     push_patch(socket,
       to: review_path(socket, invoice_id(socket.assigns.selected_invoice), %{"view" => view})
     )}
  end

  def handle_event("workbench-scope", %{"scope" => scope}, socket)
      when scope in ~w(needs_you ready all) do
    {:noreply,
     push_patch(socket,
       to: review_path(socket, invoice_id(socket.assigns.selected_invoice), %{"scope" => scope})
     )}
  end

  def handle_event("toggle-invoice-checks", _params, socket) do
    {:noreply, assign(socket, :checks_open?, not socket.assigns.checks_open?)}
  end

  def handle_event("toggle-passed-checks", _params, socket) do
    {:noreply, assign(socket, :passed_checks_open?, not socket.assigns.passed_checks_open?)}
  end

  def handle_event("toggle-checks-about", _params, socket) do
    {:noreply, assign(socket, :checks_about_open?, not socket.assigns.checks_about_open?)}
  end

  def handle_event("review-invoice-check", %{"index" => index}, socket) do
    with {index, ""} when index >= 0 <- Integer.parse(index),
         issue when is_map(issue) <- Enum.at(gst_workbench_issues(socket.assigns), index) do
      line = List.first(List.wrap(issue["lines"]))
      field = List.first(List.wrap(issue["fields"]))

      line =
        line ||
          case Regex.run(~r/line_items\[(\d+)\]/, field || "") do
            [_, number] -> String.to_integer(number) + 1
            _ -> nil
          end

      if is_integer(line) and line > 0 do
        SalesBillReview.handle_event(
          "edit-posting-line",
          %{
            "index" => to_string(line - 1),
            "return_to" => "##{invoice_check_correction_id(issue, index)}"
          },
          socket
        )
      else
        totals? =
          issue["code"] in ~w(printed_taxable_mismatch printed_tax_mismatch grand_total_mismatch)

        SalesBillReview.handle_event(
          "edit-invoice-facts",
          %{
            "field" =>
              if(issue["code"] == "invoice_period_mismatch", do: "invoice_date", else: field),
            "section" => if(totals?, do: "totals", else: "details"),
            "return_to" => "##{invoice_check_correction_id(issue, index)}"
          },
          socket
        )
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(event, params, socket), do: SalesBillReview.handle_event(event, params, socket)

  @impl true
  defdelegate handle_info(message, socket), to: SalesBillReview

  defp invoice_check_correction_id(%{"code" => "missing_taxable_value"}, _index),
    do: "invoice-workbench-correct-amounts"

  defp invoice_check_correction_id(_issue, index), do: "invoice-workbench-correct-#{index}"

  defp invoice_check_message(%{"code" => "missing_taxable_value", "lines" => lines}, invoice) do
    items =
      Enum.map_join(lines, "; ", fn number ->
        line = Enum.at(invoice["line_items"] || [], number - 1) || %{}
        name = line["description"] || line["item_name"]
        if name in [nil, ""], do: "line #{number}", else: "line #{number} (#{name})"
      end)

    "Taxable value is missing for #{items}. Enter the amount before GST."
  end

  defp invoice_check_message(issue, _invoice), do: issue["message"] || "Check invoice details"

  defp review_path(socket, source_id, overrides \\ %{}) do
    params = %{"scope" => socket.assigns.workbench_scope}

    params =
      if socket.assigns.review_batch,
        do: Map.put(params, "batch", socket.assigns.review_batch),
        else: params

    params =
      if socket.assigns.workbench_return_to,
        do: Map.put(params, "return_to", socket.assigns.workbench_return_to),
        else: params

    params =
      if socket.assigns.accounting_view?, do: Map.put(params, "view", "accounting"), else: params

    params = Map.merge(params, overrides)

    "/gst/#{socket.assigns.client.id}/#{socket.assigns.workbench_period}/sales/invoices/#{URI.encode_www_form(source_id)}?#{URI.encode_query(params)}"
  end

  # Use original PDF pages only when the invoice names pages in one known PDF.
  defp pdf_source(%{selected_invoice: nil}), do: nil

  defp pdf_source(assigns) do
    invoice = assigns.selected_invoice
    pages = List.wrap(invoice["source_pages"] || invoice["page"])

    dump =
      Enum.find(assigns.source_dumps, fn dump ->
        Enum.any?(dump.invoices, &(invoice_id(&1) == invoice_id(invoice)))
      end)

    with %{file_keys: [key]} <- dump,
         true <- String.downcase(Path.extname(key)) == ".pdf",
         true <- pages != [] && Enum.all?(pages, &(is_integer(&1) && &1 > 0)) do
      %{url: "/gst/#{dump.client_id}/#{dump.period}/original/#{dump.id}/0", pages: pages}
    else
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :pdf_source, pdf_source(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_client={@client}
      sales_period={@workbench_period}
      workbench
    >
      <section
        :if={@selected_invoice}
        id="sales-bill-posting-review"
        aria-labelledby="invoice-review-title"
        class="flex h-full min-h-0 flex-col p-4 sm:p-6"
      >
        <header class="mb-block flex shrink-0 items-center gap-4">
          <div class="min-w-0 flex-1">
            <div class="flex items-center justify-between gap-3">
              <h2 id="invoice-review-title" class="sr-only">
                Invoice {@selected_invoice["invoice_number"] || "without a number"}
              </h2>

              <div>
                <.button
                  id="sales-bill-posting-back"
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="close-posting-review"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> {if is_nil(@review_batch),
                    do: "Back to sales invoices",
                    else: "Back to batch"}
                </.button>
              </div>

              <div :if={@tally_company} class="flex items-center gap-2" id="invoice-workbench-views">
                <.button
                  id="invoice-workbench-facts-view"
                  type="button"
                  size="xs"
                  variant={if @accounting_view?, do: "ghost", else: "soft"}
                  phx-click="workbench-view"
                  phx-value-view="invoice"
                >Invoice</.button>
                <.button
                  id="invoice-workbench-accounting-view"
                  type="button"
                  size="xs"
                  variant={if @accounting_view?, do: "soft", else: "ghost"}
                  phx-click="workbench-view"
                  phx-value-view="accounting"
                >Accounting</.button>
              </div>

              <div class="border-rule gap-related flex items-center border-r pr-4">
                <.segmented_control
                  :if={@workbench_context && @workbench_period}
                  id="invoice-workbench-scope"
                  items={[
                    {:needs_you, "Needs review (#{length(@workbench_context.review.needs_you)})"},
                    {:ready,
                     "Ready (#{length(@workbench_context.review.all) - length(@workbench_context.review.needs_you)})"},
                    {:all, "All (#{length(@workbench_context.review.all)})"}
                  ]}
                  selected={@workbench_context.scope}
                  on_change="workbench-scope"
                  value_name="scope"
                />
                <.button
                  :if={@workbench_context && @workbench_period}
                  id="invoice-workbench-queue-toggle"
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="toggle-invoice-queue"
                  aria-expanded={@invoice_queue_open?}
                >
                  <.icon name="hero-list-bullet" class="size-4" />
                  <span class="sr-only">Show invoice queue</span>
                </.button>

                <.button
                  id="sales-bill-posting-previous"
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="navigate-posting-review"
                  phx-value-item={invoice_id(@posting_navigation.previous)}
                  disabled={is_nil(@posting_navigation.previous)}
                  aria-label="Previous invoice"
                  title="Previous invoice"
                >
                  <.icon name="hero-chevron-left" class="size-4" />
                </.button>

                <span id="sales-bill-posting-position" class="text-ink-subtle text-ui tabular-nums">
                  {if @posting_navigation.position == 0,
                    do: "#{@posting_navigation.total} remaining",
                    else: "#{@posting_navigation.position} of #{@posting_navigation.total}"}
                </span>

                <.button
                  id="sales-bill-posting-next"
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="navigate-posting-review"
                  phx-value-item={invoice_id(@posting_navigation.next)}
                  disabled={is_nil(@posting_navigation.next)}
                  aria-label="Next invoice"
                  title="Next invoice"
                >
                  <.icon name="hero-chevron-right" class="size-4" />
                </.button>
              </div>
            </div>
          </div>

          <.button
            id="invoice-review-close"
            variant="ghost"
            phx-click="close-posting-review"
            aria-label="Close invoice review"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </.button>
        </header>

        <div class="min-h-0 flex-1 overflow-y-auto">
          <div
            :if={@invoice_queue_open? && @workbench_context}
            id="invoice-workbench-queue"
            class="border-rule space-y-related border-b pb-3"
          >
            <div class="flex flex-wrap gap-2">
              <.button
                :for={item <- @workbench_context.queue}
                id={"invoice-queue-#{item.source_id}"}
                type="button"
                size="xs"
                variant="outline"
                phx-click="navigate-posting-review"
                phx-value-item={item.source_id}
              >
                {item.invoice["invoice_number"]}
                <span :if={item.open_actionable_targets != []}>· Needs review</span>
              </.button>
            </div>
          </div>

          <div
            :if={review_queue_empty?(@workbench_context, @workbench_period)}
            id="invoice-workbench-review-complete"
            phx-hook=".SalesBillPostingReviewKeys"
            data-navigation-enabled="true"
            class="space-y-block"
          >
            <p>No invoices need review.</p>

            <.button id="invoice-workbench-review-done" phx-click="close-posting-review">
              Back to sales invoices
            </.button>
          </div>

          <div
            :if={not review_queue_empty?(@workbench_context, @workbench_period)}
            id="sales-bill-posting-review-keys"
            phx-hook=".SalesBillPostingReviewKeys"
            data-previous-item={invoice_id(@posting_navigation.previous)}
            data-next-item={invoice_id(@posting_navigation.next)}
            data-navigation-enabled={
              if(
                is_nil(@editing_line_index) and not @editing_invoice_facts? and not @evidence_open and
                  @ledger_picker.status != :open,
                do: "true",
                else: "false"
              )
            }
            class="gap-block grid h-full min-h-0 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:grid-rows-[minmax(0,1fr)]"
          >
            <section
              id="sales-bill-original"
              class={[
                "border-rule min-h-0 overflow-y-auto border-r",
                is_nil(@pdf_source) && "bg-canvas p-3"
              ]}
            >
              <NilaWeb.Components.PdfViewer.viewer
                :if={@pdf_source}
                id={"invoice-pdf-#{invoice_id(@selected_invoice)}"}
                url={@pdf_source.url}
                pages={@pdf_source.pages}
              >
                <:fallback :if={@selected_invoice["image_urls"] != []}>
                  <.evidence_frame
                    id="sales-bill-pdf-fallback"
                    images={@selected_invoice["image_urls"]}
                    page={@evidence_page}
                    label="Invoice page"
                    on_open="open-posting-evidence"
                    on_page="posting-evidence-page"
                  />
                </:fallback>
              </NilaWeb.Components.PdfViewer.viewer>
              <.evidence_frame
                :if={is_nil(@pdf_source) && @selected_invoice["image_urls"] != []}
                id="sales-bill-evidence-frame"
                images={@selected_invoice["image_urls"]}
                page={@evidence_page}
                label="Original invoice"
                on_open="open-posting-evidence"
                on_page="posting-evidence-page"
              />
              <div
                :if={is_nil(@pdf_source) && @selected_invoice["image_urls"] == []}
                id="sales-bill-evidence-unavailable"
                class="border-rule rounded-box text-body text-ink-muted flex h-full min-h-48 items-center justify-center border border-dashed"
              >
                No rendered invoice page is available.
              </div>
            </section>

            <section
              id="sales-bill-proposed-voucher"
              class="bg-panel-surface min-h-0 overflow-y-auto px-4 pt-4"
            >
              <div
                :if={@accounting_view? && @tally_company && not @tally_masters_available?}
                id="sales-bill-tally-masters-unavailable"
              >
                <.callout kind="warning" size="compact" title="Import Tally ledgers to get started">
                  {tally_master_sync_instruction(assigns)}
                </.callout>
              </div>

              <div
                :if={@accounting_view? && is_nil(@tally_company)}
                id="sales-bill-tally-company-unavailable"
              >
                <.callout kind="warning" size="compact" title="No Tally company selected">
                  Select this client's Tally company to choose posting ledgers and send vouchers.
                </.callout>
              </div>

              <.form
                :if={@tally_posting}
                for={@tally_posting.form}
                id="sales-bill-tally-posting-form"
                phx-submit="save-tally-posting"
                phx-change="preview-tally-posting"
              >
                <div class="pb-canvas space-y-section">
                  <section id="sales-bill-invoice-facts" class="space-y-section">
                    <div class="space-y-section">
                      <div id="invoice-workbench-heading" class="space-y-related">
                        <h3
                          id="sales-bill-invoice-identity"
                          class="text-base-content text-page font-medium"
                        >
                          Invoice {@posting_preview_invoice["invoice_number"] || "without a number"}
                        </h3>

                        <p
                          :if={@posting_preview_invoice["invoice_date"]}
                          id="sales-bill-invoice-date"
                          class="text-ink-muted text-ui"
                        >
                          {format_display_date(@posting_preview_invoice["invoice_date"])}
                        </p>
                      </div>

                      <div class="border-rule gap-block pb-section flex items-start justify-between border-b">
                        <div class="space-y-related min-w-0">
                          <p id="sales-bill-buyer-identity" class="text-body font-medium">
                            {@posting_preview_invoice["buyer_name"] || "Buyer not identified"}
                          </p>

                          <p
                            :if={@posting_preview_invoice["buyer_gstin"]}
                            id="sales-bill-buyer-gstin"
                            class="text-ink-muted text-ui"
                          >
                            GSTIN {@posting_preview_invoice["buyer_gstin"]}
                          </p>

                          <p :if={@accounting_view? && @tally_company} class="text-ink-muted text-ui">
                            Tally · {@tally_company.name}
                            <span
                              :if={not @tally_online? && @tally_masters_available?}
                              id="sales-bill-tally-offline"
                              class="text-warning"
                            >
                              · Offline — masters synced {format_master_sync(@tally_masters_synced_at)}
                            </span>
                          </p>

                          <p
                            :if={not @accounting_view? && @workbench_context}
                            id="invoice-workbench-treatment"
                            class="text-ink-muted text-ui"
                          >
                            {String.upcase(@workbench_context.item.treatment["table"] || "")} · Place of supply: {place_of_supply_label(
                              @workbench_context.item.treatment["place_of_supply"]
                            )}
                          </p>
                        </div>

                        <.button
                          id="sales-bill-edit-invoice-facts"
                          data-shortcut-edit
                          aria-keyshortcuts="e"
                          title="Edit invoice details (E)"
                          type="button"
                          variant="ghost"
                          size="sm"
                          phx-click="edit-invoice-facts"
                          phx-value-return_to="#sales-bill-edit-invoice-facts"
                        >
                          <.icon name="hero-pencil-square" class="size-4" /> Edit invoice details
                        </.button>
                      </div>
                    </div>

                    <.callout
                      :for={{item, index} <- Enum.with_index(review_items(@selected_review, :facts))}
                      kind="warning"
                      size="compact"
                      title={item.summary}
                    >
                      <div class="gap-related flex items-start justify-between">
                        <span>{review_item_copy(item)}</span>
                        <.button
                          id={"sales-bill-fix-invoice-fact-#{index}"}
                          type="button"
                          variant="ghost"
                          size="xs"
                          phx-click="edit-invoice-facts"
                          phx-value-field={review_item_focus(item)}
                          phx-value-return_to={"#sales-bill-fix-invoice-fact-#{index}"}
                        >
                          Fix
                        </.button>
                      </div>
                    </.callout>

                    <div>
                      <.input
                        id="tally-posting-invoice-number-value"
                        name="tally_posting[invoice][invoice_number]"
                        value={@posting_preview_invoice["invoice_number"]}
                        type="hidden"
                      />
                      <.input
                        id="tally-posting-invoice-date-value"
                        name="tally_posting[invoice][invoice_date]"
                        value={@posting_preview_invoice["invoice_date"]}
                        type="hidden"
                      />
                      <.input
                        id="tally-posting-buyer-name-value"
                        name="tally_posting[invoice][buyer_name]"
                        value={@posting_preview_invoice["buyer_name"]}
                        type="hidden"
                      />
                      <.input
                        id="tally-posting-buyer-gstin-value"
                        name="tally_posting[invoice][buyer_gstin]"
                        value={@posting_preview_invoice["buyer_gstin"]}
                        type="hidden"
                      />
                    </div>
                  </section>

                  <section
                    :if={review_items(@selected_review, :global) != []}
                    id="sales-bill-global-review"
                    class="space-y-related max-w-3xl"
                  >
                    <div
                      :for={{item, index} <- Enum.with_index(review_items(@selected_review, :global))}
                      id={"sales-bill-review-global-#{index}"}
                    >
                      <.callout kind="warning" size="compact" title={item.summary}>
                        <span :if={item.detail}>{item.detail}</span>
                      </.callout>
                    </div>
                  </section>

                  <section id="sales-bill-accounting-mappings" class="space-y-block">
                    <div :if={@accounting_view?} class="space-y-related max-w-3xl">
                      <div class="gap-related flex items-baseline">
                        <h3 class="text-base-content text-h4 font-semibold">Accounting mappings</h3>

                        <span id="sales-bill-mappings-remaining" class="text-ink-muted text-ui">
                          {if(@tally_masters_available?,
                            do: missing_mapping_text(@tally_posting),
                            else: "Available after master sync"
                          )}
                        </span>
                      </div>

                      <div id="sales-bill-party-mapping" class="max-w-lg">
                        <.ledger_picker_field
                          id="tally_posting_party_ledger_identity"
                          name="tally_posting[party_ledger_identity]"
                          label="Tally party ledger"
                          prompt="Select party ledger"
                          options={@tally_posting.party_choices}
                          value={@tally_posting.form[:party_ledger_identity].value}
                          picker="party"
                          panel_id="sales-bill-ledger-picker"
                          on_open="open-ledger-picker"
                          expanded={
                            @ledger_picker.status == :open and @ledger_picker.picker == "party"
                          }
                          disabled={not @tally_masters_available?}
                        />
                      </div>
                    </div>

                    <section id="sales-bill-ledger-allocations" class="space-y-related">
                      <div class="flex items-baseline justify-between gap-3">
                        <h3 class="text-base-content text-ui font-semibold">
                          {if @accounting_view?, do: "Ledger allocations", else: "Invoice lines"}
                        </h3>

                        <span class="text-ink-subtle text-ui">
                          {length(@tally_posting.line_rows)} {plural(
                            length(@tally_posting.line_rows),
                            "line"
                          )}
                        </span>
                      </div>

                      <div
                        :for={
                          {item, index} <-
                            Enum.with_index(review_items(@selected_review, :allocations))
                        }
                        id={"sales-bill-review-allocation-#{index}"}
                      >
                        <.callout kind="warning" size="compact" title={item.summary}>
                          <span>{review_item_copy(item)}</span>
                        </.callout>
                      </div>

                      <.data_table
                        id="sales-bill-posting-lines"
                        surface={if @accounting_view?, do: "surface", else: "framed"}
                        rows={@tally_posting.line_rows}
                        row_id={fn row -> "sales-bill-posting-line-#{row.index}" end}
                        mode="review"
                        min_width={if @accounting_view?, do: "min-w-[760px]", else: nil}
                      >
                        <:col :let={row} label="Invoice line" row_header class="w-2/5 min-w-72">
                          <div id={"sales-bill-line-summary-#{row.index}"} class="space-y-1">
                            <p class="text-base-content text-ui font-medium">
                              {row.line["description"] || row.line["item_name"] || "Unnamed line"}
                            </p>

                            <p class="text-ink-muted text-ui">
                              HSN {row.line["hsn_sac"] || "—"} · {working_number(row.line["quantity"])} {row.line[
                                "uom"
                              ]} × {rupees(
                                row.line["printed_unit_price"] || row.line["unit_price"] ||
                                  row.line["rate"]
                              )}
                            </p>

                            <p
                              :for={item <- review_line_items(@selected_review, row.index)}
                              class="text-ui text-warning font-medium"
                            >
                              {item.summary}
                            </p>

                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][description]"}
                              value={row.line["description"] || row.line["item_name"]}
                            />
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][hsn_sac]"}
                              value={row.line["hsn_sac"]}
                            />
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][quantity]"}
                              value={row.line["quantity"]}
                            />
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][uom]"}
                              value={row.line["uom"]}
                            />
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][rate]"}
                              value={
                                row.line["printed_unit_price"] || row.line["unit_price"] ||
                                  row.line["rate"]
                              }
                            />
                          </div>
                        </:col>

                        <:col :let={row} label="Taxable" align="right" class="w-32">
                          <div class="tabular-nums">
                            <span class="text-base-content text-ui block font-medium">
                              {if is_nil(row.line["taxable_value"]),
                                do: "Missing",
                                else: rupees(row.line["taxable_value"])}
                            </span>
                          </div>

                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][taxable_value]"}
                            value={row.line["taxable_value"]}
                          />
                        </:col>

                        <:col :let={row} label="GST" align="right" class="w-44">
                          <div class="space-y-1 text-right tabular-nums">
                            <span :if={row.tax_rows == []} class="text-ink-muted text-ui">—</span>
                            <div
                              :for={tax <- row.tax_rows}
                              class="text-ui flex items-baseline justify-end gap-1 whitespace-nowrap tabular-nums"
                            >
                              <span class="text-ink-muted whitespace-nowrap">
                                {tax.label} {working_number(tax.rate)}%
                              </span>

                              <span class="text-base-content whitespace-nowrap">
                                · {rupees(tax.amount)}
                              </span>

                              <.input
                                type="hidden"
                                name={"tally_posting[invoice][line_items][#{row.index}][#{tax.head}_rate]"}
                                value={tax.rate}
                              />
                              <.input
                                type="hidden"
                                name={"tally_posting[invoice][line_items][#{row.index}][#{tax.head}_amount]"}
                                value={tax.amount}
                              />
                            </div>
                          </div>
                        </:col>

                        <:col
                          :let={row}
                          :if={@accounting_view?}
                          label="Tally sales ledger"
                          class="w-1/4 min-w-60 align-middle"
                        >
                          <.ledger_picker_field
                            id={"tally-posting-line-sales-ledger-#{row.index}"}
                            name={"tally_posting[line_sales_ledger_identities][#{row.index}]"}
                            value={row.sales_ledger_identity}
                            label={"Line #{row.index + 1} Tally sales ledger"}
                            prompt="Select ledger"
                            options={@tally_posting.sales_choices}
                            picker={"sales:#{row.index}"}
                            panel_id="sales-bill-ledger-picker"
                            on_open="open-ledger-picker"
                            expanded={
                              @ledger_picker.status == :open and
                                @ledger_picker.picker == "sales:#{row.index}"
                            }
                            hide_label
                            disabled={not @tally_masters_available?}
                          />
                        </:col>

                        <:col :let={row} label="" align="center" class="w-10 align-middle">
                          <button
                            id={"sales-bill-edit-line-#{row.index}"}
                            type="button"
                            class={[
                              "focus-visible:outline-focus rounded-field text-ink-muted grid size-8 place-items-center transition focus-visible:outline-2 focus-visible:outline-offset-2",
                              not invoice_frozen?(
                                @tally_jobs,
                                @selected_invoice,
                                @packet.all_invoices
                              ) &&
                                "hover:bg-interactive hover:text-ink cursor-pointer",
                              invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices) &&
                                "cursor-not-allowed opacity-50"
                            ]}
                            phx-click="edit-posting-line"
                            phx-value-index={row.index}
                            disabled={
                              invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)
                            }
                            aria-label={"Edit invoice line #{row.index + 1}"}
                            title={
                              if(
                                invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices),
                                do: "Locked after sending",
                                else: "Edit line"
                              )
                            }
                          >
                            <.icon name="hero-pencil-square" class="size-4" />
                          </button>
                        </:col>
                      </.data_table>
                    </section>

                    <section
                      :if={not @accounting_view?}
                      id="invoice-workbench-totals"
                      class="space-y-block"
                    >
                      <div class="flex items-center justify-between">
                        <h3 class="text-ui font-semibold">Invoice totals</h3>

                        <.button
                          id="invoice-workbench-edit-totals"
                          type="button"
                          variant="ghost"
                          size="xs"
                          phx-click="edit-invoice-facts"
                          phx-value-section="totals"
                          phx-value-return_to="#invoice-workbench-edit-totals"
                        >
                          <.icon name="hero-pencil-square" class="size-4" /> Edit printed totals
                        </.button>
                      </div>

                      <.data_table
                        id="invoice-totals-comparison"
                        surface="framed"
                        mode="scan"
                        rows={invoice_total_rows(@posting_preview_invoice)}
                      >
                        <:col :let={row} label="Total" row_header>
                          <span class={row.field == :total && "font-semibold"}>{row.label}</span>
                        </:col>

                        <:col :let={row} label="From lines" align="right">
                          <span class={row.field == :total && "font-semibold"}>
                            {if is_nil(row.calculated),
                              do: "Not calculated",
                              else: rupees(row.calculated)}
                          </span>
                        </:col>

                        <:col :let={row} label="Printed on bill" align="right">
                          <span class={[
                            row.mismatch? && "text-error",
                            row.field == :total && "font-semibold"
                          ]}>
                            {if is_nil(row.printed), do: "Not captured", else: rupees(row.printed)}
                          </span>
                        </:col>

                        <:col :let={row} label="Comparison" class="w-44">
                          <span
                            :if={row.matches?}
                            id={"invoice-total-match-#{row.field}"}
                            class="text-ink-muted text-ui inline-flex items-center gap-2"
                          >
                            <span
                              aria-hidden="true"
                              class="bg-success inline-block size-1.5 rounded-full"
                            /> Matches
                          </span>

                          <p :if={row.mismatch?} class="text-error text-ui">
                            Difference {rupees(row.difference)}
                          </p>
                          <span :if={!row.matches? && !row.mismatch?} class="text-ink-muted">—</span>
                        </:col>
                      </.data_table>
                    </section>

                    <section
                      :if={@accounting_view?}
                      id="sales-bill-tax-posting"
                      class="space-y-related max-w-3xl"
                    >
                      <h3 class="text-base-content text-ui font-semibold">Tax ledgers</h3>

                      <div
                        :for={row <- @tally_posting.tax_rows}
                        id={"sales-bill-tax-row-#{row.head}"}
                        class="gap-block grid items-center sm:grid-cols-[7rem_minmax(0,32rem)_auto]"
                      >
                        <span class="text-base-content text-ui font-medium">
                          {tax_posting_label(@posting_preview_invoice, row.head, row.label)}
                        </span>

                        <.ledger_picker_field
                          id={"tally_posting_#{row.head}_ledger_identity"}
                          name={"tally_posting[#{row.head}_ledger_identity]"}
                          prompt={"Select #{row.label} ledger"}
                          options={Map.get(@tally_posting.tax_choices, row.head, [])}
                          value={@tally_posting.form[row.field].value}
                          label={"#{row.label} ledger"}
                          picker={"tax:#{row.head}"}
                          panel_id="sales-bill-ledger-picker"
                          on_open="open-ledger-picker"
                          expanded={
                            @ledger_picker.status == :open and
                              @ledger_picker.picker == "tax:#{row.head}"
                          }
                          hide_label
                          disabled={not @tally_masters_available?}
                        />
                        <span class="text-base-content text-ui text-right font-medium tabular-nums">
                          {rupees(row.amount)}
                        </span>
                      </div>
                    </section>
                  </section>

                  <section
                    :if={@accounting_view?}
                    id="sales-bill-narration"
                    class="space-y-related max-w-3xl"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <h3 class="text-base-content text-ui font-semibold">Narration</h3>

                      <.button
                        :if={not @editing_narration?}
                        id="sales-bill-edit-narration"
                        type="button"
                        variant="ghost"
                        size="xs"
                        phx-click="edit-narration"
                      >
                        Edit
                      </.button>

                      <.button
                        :if={@editing_narration?}
                        id="sales-bill-finish-narration"
                        type="button"
                        variant="ghost"
                        size="xs"
                        phx-click="finish-narration"
                      >
                        Done
                      </.button>
                    </div>

                    <p
                      :if={not @editing_narration?}
                      id="sales-bill-narration-value"
                      class="text-ink-muted text-ui"
                    >
                      {narration(@posting_preview_invoice)}
                    </p>

                    <.input
                      :if={not @editing_narration?}
                      id="tally-posting-narration-value"
                      name="tally_posting[invoice][narration]"
                      value={narration(@posting_preview_invoice)}
                      type="hidden"
                    />
                    <.input
                      :if={@editing_narration?}
                      id="tally-posting-narration"
                      name="tally_posting[invoice][narration]"
                      value={narration(@posting_preview_invoice)}
                      type="textarea"
                      aria-label="Narration"
                      rows="2"
                    />
                  </section>

                  <p
                    :if={@send_error}
                    id="sales-bill-posting-send-error"
                    class="text-error text-ui"
                  >
                    {@send_error}
                  </p>

                  <div
                    :if={
                      selected_delivery_state(
                        selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                      ) ==
                        :sending
                    }
                    id="sales-bill-posting-sending"
                    class="text-base-content text-ui flex items-center gap-2 font-semibold"
                  >
                    <.spinner tone="accent" label="Sending to Tally" /> Sending to Tally
                  </div>

                  <p
                    :if={
                      selected_delivery_state(
                        selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                      ) ==
                        :added
                    }
                    id="sales-bill-posting-added"
                    class="text-success text-ui font-semibold"
                  >
                    Added to Tally and verified
                  </p>

                  <.callout
                    :if={
                      selected_delivery_state(
                        selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                      ) ==
                        :unknown
                    }
                    kind="warning"
                    size="compact"
                    title="Tally outcome needs verification"
                  >
                    Nila could not confirm whether this voucher was added. Use Check Tally from the batch.
                  </.callout>

                  <p
                    :if={
                      selected_delivery_state(
                        selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                      ) ==
                        :failed
                    }
                    id="sales-bill-posting-failed"
                    class="text-error text-ui"
                  >
                    This voucher was not added to Tally. Correct it and try again.
                  </p>
                </div>

                <div
                  :if={not @accounting_view?}
                  id="invoice-workbench-footer"
                  class="bg-panel-surface border-rule sticky bottom-0 flex items-start justify-between gap-4 border-t py-4"
                >
                  <NilaWeb.Components.Gst.InvoiceChecks.summary
                    invoice={@posting_preview_invoice}
                    open={@checks_open?}
                    passed_open={@passed_checks_open?}
                    about_open={@checks_about_open?}
                    batch={@packet.all_invoices}
                    issues={gst_workbench_issues(assigns)}
                  >
                    <:issue_actions>
                      <section
                        :if={gst_workbench_issues(assigns) != []}
                        id="invoice-workbench-gst"
                        class="space-y-block"
                      >
                        <div
                          :for={{issue, index} <- Enum.with_index(gst_workbench_issues(assigns))}
                          id={
                            if issue["code"] == "missing_taxable_value",
                              do: "invoice-workbench-incomplete",
                              else: "invoice-workbench-issue-#{index}"
                          }
                        >
                          <div
                            :if={issue["code"] == "missing_hsn_sac"}
                            class="gap-related text-ui flex flex-wrap items-center"
                          >
                            <span>
                              HSN/SAC missing on {length(issue["lines"])} {plural(
                                length(issue["lines"]),
                                "line"
                              )}
                            </span>

                            <.button
                              id="invoice-workbench-review-hsn"
                              type="button"
                              size="xs"
                              variant="ghost"
                              phx-click="edit-posting-line"
                              phx-value-index={hd(issue["lines"]) - 1}
                              phx-value-return_to="#invoice-workbench-review-hsn"
                              disabled={
                                invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)
                              }
                            >
                              Review codes
                            </.button>
                          </div>

                          <.callout
                            :if={issue["code"] != "missing_hsn_sac"}
                            kind="warning"
                            size="compact"
                            title={invoice_check_message(issue, @posting_preview_invoice)}
                          >
                            <div class="mt-related flex gap-2">
                              <.button
                                :if={
                                  @workbench_context && not Nila.Gst.Sales.Workings.blocking?(issue)
                                }
                                id={"invoice-workbench-confirm-#{index}"}
                                type="button"
                                size="xs"
                                phx-click="confirm-gst-issue"
                                phx-value-target={Nila.Gst.Sales.Workings.issue_key(issue)}
                              >
                                {if issue["code"] in ~w(seller_identity_unverified seller_identity_mismatch),
                                  do: "Confirm this belongs to this client",
                                  else: "Keep extracted value"}
                              </.button>

                              <.button
                                :if={
                                  issue["code"] not in ~w(seller_identity_unverified seller_identity_mismatch)
                                }
                                id={invoice_check_correction_id(issue, index)}
                                type="button"
                                size="xs"
                                variant="outline"
                                phx-click="review-invoice-check"
                                phx-value-index={index}
                                phx-value-field={
                                  if issue["code"] == "invoice_period_mismatch", do: "invoice_date"
                                }
                              >{if issue["code"] == "invoice_period_mismatch",
                                do: "Correct date",
                                else: "Correct values"}</.button>
                              <.button
                                :if={issue["code"] == "missing_taxable_value"}
                                id="invoice-workbench-exclude-incomplete"
                                type="button"
                                size="xs"
                                variant="outline"
                                phx-click="remove-invoice"
                                phx-value-id={invoice_id(@selected_invoice)}
                                disabled={
                                  invoice_frozen?(
                                    @tally_jobs,
                                    @selected_invoice,
                                    @packet.all_invoices
                                  )
                                }
                              >Exclude invoice</.button>
                              <.button
                                :if={issue["code"] == "invoice_period_mismatch"}
                                id="invoice-workbench-exclude-period-mismatch"
                                type="button"
                                size="xs"
                                variant="outline"
                                phx-click="remove-invoice"
                                phx-value-id={invoice_id(@selected_invoice)}
                              >
                                Exclude from working
                              </.button>
                            </div>
                          </.callout>
                        </div>
                      </section>
                    </:issue_actions>
                  </NilaWeb.Components.Gst.InvoiceChecks.summary>

                  <.button
                    id="invoice-workbench-next"
                    type="button"
                    phx-click={
                      if @posting_navigation.next,
                        do: "navigate-posting-review",
                        else: "close-posting-review"
                    }
                    phx-value-item={invoice_id(@posting_navigation.next)}
                  >
                    {if @posting_navigation.next, do: "Next invoice", else: "Done"}
                  </.button>
                </div>

                <div
                  :if={@accounting_view?}
                  class="bg-panel-surface border-rule sticky bottom-0 border-t py-4"
                >
                  <div
                    :if={@selected_review}
                    id="sales-bill-next-review-issue"
                    class="gap-block flex flex-col lg:flex-row lg:items-center lg:justify-between"
                  >
                    <div class="min-w-0">
                      <p class="text-base-content text-ui font-semibold">
                        {length(@selected_review.items)} {plural(
                          length(@selected_review.items),
                          "review issue"
                        )}
                      </p>

                      <p class="text-ink-muted text-ui truncate">
                        Next: {next_review_item(@selected_review).summary}
                      </p>
                    </div>

                    <div class="gap-block flex items-center justify-end">
                      <p class="text-base-content text-ui font-semibold tabular-nums">
                        {rupees(invoice_total(@posting_preview_invoice))}
                      </p>

                      <.button
                        id="sales-bill-go-to-review-issue"
                        type="button"
                        variant="outline"
                        phx-click={
                          JS.focus(to: review_item_target(next_review_item(@selected_review)))
                        }
                      >
                        Review
                      </.button>

                      <.button
                        :if={
                          @tally_masters_available? &&
                            is_nil(next_posting_requirement(@tally_posting))
                        }
                        id="sales-bill-save-tally-posting-intentionally"
                        type="submit"
                        disabled={
                          invoice_frozen?(
                            @tally_jobs,
                            @selected_invoice,
                            @packet.all_invoices
                          )
                        }
                      >
                        {if(@review_mode?,
                          do: "Save & next intentionally",
                          else: "Save & Close intentionally"
                        )}
                      </.button>
                    </div>
                  </div>

                  <div
                    :if={
                      is_nil(@selected_review) && @tally_masters_available? &&
                        next_posting_requirement(@tally_posting)
                    }
                    id="sales-bill-next-required-mapping"
                    class="gap-block flex flex-col lg:flex-row lg:items-center lg:justify-between"
                  >
                    <div class="min-w-0">
                      <p class="text-base-content text-ui font-semibold">
                        {length(posting_requirements(@tally_posting))} {plural(
                          length(posting_requirements(@tally_posting)),
                          "mapping"
                        )} left
                      </p>

                      <p class="text-ink-muted text-ui truncate">
                        Next: {next_posting_requirement(@tally_posting).label}
                      </p>
                    </div>

                    <div class="gap-block flex items-center justify-end">
                      <p class="text-base-content text-ui font-semibold tabular-nums">
                        {rupees(invoice_total(@posting_preview_invoice))}
                      </p>

                      <.ledger_picker_shortcut
                        id="sales-bill-go-to-required-mapping"
                        picker={next_posting_requirement(@tally_posting).picker}
                        on_open="open-ledger-picker"
                      >
                        Choose ledger
                      </.ledger_picker_shortcut>
                    </div>
                  </div>

                  <div
                    :if={
                      is_nil(@selected_review) && @tally_masters_available? &&
                        is_nil(next_posting_requirement(@tally_posting))
                    }
                    id="sales-bill-posting-ready"
                    class="gap-block flex flex-col lg:flex-row lg:items-end lg:justify-between"
                  >
                    <dl class="text-ui grid flex-1 grid-cols-3 gap-3">
                      <div>
                        <dt class="text-ink-subtle">Taxable</dt>

                        <dd class="text-base-content mt-1 font-medium tabular-nums">
                          {rupees(totals(@posting_preview_invoice).taxable)}
                        </dd>
                      </div>

                      <div>
                        <dt class="text-ink-subtle">Tax</dt>

                        <dd class="text-base-content mt-1 font-medium tabular-nums">
                          {rupees(totals(@posting_preview_invoice).tax)}
                        </dd>
                      </div>

                      <div>
                        <dt class="text-base-content font-medium">Voucher total</dt>

                        <dd class="text-base-content mt-1 font-semibold tabular-nums">
                          {rupees(invoice_total(@posting_preview_invoice))}
                        </dd>
                      </div>
                    </dl>

                    <div class="gap-related flex justify-end">
                      <.button
                        id="sales-bill-save-tally-posting"
                        type="submit"
                        disabled={
                          invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)
                        }
                      >
                        {if(@review_mode?, do: "Save & next", else: "Save & Close")}
                      </.button>
                    </div>
                  </div>

                  <div
                    :if={not @tally_masters_available?}
                    id="sales-bill-posting-awaiting-masters"
                    class="gap-block flex items-end justify-between"
                  >
                    <p class="text-ink-muted text-ui">
                      Tally mappings are available after the first master sync.
                    </p>

                    <p class="text-base-content text-ui font-semibold tabular-nums">
                      {rupees(invoice_total(@posting_preview_invoice))}
                    </p>
                  </div>
                </div>
              </.form>

              <.ledger_picker_panel
                :if={@tally_posting}
                id="sales-bill-ledger-picker"
                title={@ledger_picker.title}
                form={@ledger_picker.form}
                options={@ledger_picker.options}
                selected_identity={@ledger_picker.selected_identity}
                on_filter="filter-ledger-picker"
                on_submit="choose-first-ledger"
                on_select="choose-ledger"
                on_close="close-ledger-picker"
                picker={@ledger_picker.picker}
                trigger_id={@ledger_picker.trigger_id}
                generation={@ledger_picker.generation}
                open={@ledger_picker.status == :open}
              />
              <.modal
                :if={@editing_invoice_facts? && @invoice_facts_form}
                id="sales-bill-invoice-facts-sheet"
                title={
                  if @invoice_facts_section == "totals",
                    do: "Edit printed totals",
                    else: "Edit invoice details"
                }
                on_close="close-invoice-facts"
                variant="sheet"
                side="right"
                return_focus={@invoice_facts_return_focus}
              >
                <.form
                  for={@invoice_facts_form}
                  id="sales-bill-invoice-facts-form"
                  data-shortcut-save
                  aria-keyshortcuts="Control+Enter Meta+Enter"
                  phx-hook=".InvoiceFactsFocus"
                  data-focus-field={@invoice_facts_focus}
                  phx-submit="save-invoice-facts"
                  class="space-y-block p-6"
                >
                  <div :if={@invoice_facts_section == "details"} class="space-y-block">
                    <div class="gap-block grid grid-cols-2">
                      <.input
                        field={@invoice_facts_form[:invoice_number]}
                        label="Invoice number"
                        required
                        autofocus={@invoice_facts_focus == "invoice_number"}
                      />
                      <.input
                        field={@invoice_facts_form[:invoice_date]}
                        type="date"
                        label="Invoice date"
                        required
                        autofocus={@invoice_facts_focus == "invoice_date"}
                      />
                    </div>

                    <.input
                      field={@invoice_facts_form[:buyer_name]}
                      label="Buyer name"
                      required
                      autofocus={@invoice_facts_focus == "buyer_name"}
                    />
                    <.input
                      field={@invoice_facts_form[:buyer_gstin]}
                      label="Buyer GSTIN"
                      autofocus={@invoice_facts_focus == "buyer_gstin"}
                    />
                    <.input
                      field={@invoice_facts_form[:place_of_supply]}
                      label="Place of supply (state code)"
                      autofocus={@invoice_facts_focus == "place_of_supply"}
                    />
                  </div>

                  <section
                    :if={@invoice_facts_section == "totals"}
                    id="invoice-facts-printed-totals"
                    class="space-y-block"
                  >
                    <.input
                      field={@invoice_facts_form[:printed_total_taxable]}
                      type="text"
                      inputmode="decimal"
                      label="Taxable total"
                    />
                    <.input
                      field={@invoice_facts_form[:printed_total_tax]}
                      type="text"
                      inputmode="decimal"
                      label="Total tax"
                    />
                    <.input
                      field={@invoice_facts_form[:printed_grand_total]}
                      type="text"
                      inputmode="decimal"
                      label="Grand total"
                    />
                  </section>

                  <p
                    :if={@invoice_facts_error}
                    id="sales-bill-invoice-facts-error"
                    class="text-error text-ui"
                  >
                    {@invoice_facts_error}
                  </p>
                </.form>

                <:footer>
                  <.button type="button" variant="ghost" phx-click="close-invoice-facts">
                    Cancel
                  </.button>

                  <.button type="submit" form="sales-bill-invoice-facts-form">
                    Save changes
                  </.button>
                </:footer>
              </.modal>

              <.modal
                :if={@line_edit_form && @line_edit_row}
                id="sales-bill-line-edit-sheet"
                title={"Edit line #{@editing_line_index + 1}"}
                on_close="close-posting-line"
                variant="sheet"
                side="right"
                return_focus={@line_edit_return_focus}
              >
                <.form
                  for={@line_edit_form}
                  id="sales-bill-line-edit-form"
                  data-shortcut-save
                  aria-keyshortcuts="Control+Enter Meta+Enter"
                  phx-submit="save-posting-line"
                  class="space-y-block p-6"
                >
                  <p class="text-ink text-ui font-semibold">{@line_edit_form[:description].value}</p>
                  <.input
                    field={@line_edit_form[:description]}
                    label="Description"
                    required
                  /> <.input field={@line_edit_form[:hsn_sac]} label="HSN / SAC" required />
                  <div
                    :if={@workbench_context && line_missing_hsn_issue(assigns)}
                    class="space-y-related"
                  >
                    <p class="text-ink-muted text-ui">
                      HSN/SAC is missing on {length(line_missing_hsn_issue(assigns)["lines"])} {plural(
                        length(line_missing_hsn_issue(assigns)["lines"]),
                        "line"
                      )}.
                      Confirm only if you have reviewed all affected lines and intend to leave these codes blank.
                    </p>

                    <.button
                      id="invoice-workbench-confirm-missing-hsn"
                      type="button"
                      size="xs"
                      variant="outline"
                      phx-click="confirm-gst-issue"
                      phx-value-target={
                        Nila.Gst.Sales.Workings.issue_key(line_missing_hsn_issue(assigns))
                      }
                    >
                      Confirm missing codes
                    </.button>
                  </div>

                  <div class="gap-block grid grid-cols-2">
                    <.input
                      field={@line_edit_form[:quantity]}
                      type="number"
                      label="Quantity"
                      step="any"
                    /> <.input field={@line_edit_form[:uom]} label="Unit" />
                  </div>

                  <div class="gap-block grid grid-cols-2">
                    <.input
                      field={@line_edit_form[:rate]}
                      type="number"
                      label="Unit price"
                      step="any"
                    />
                    <.input
                      field={@line_edit_form[:taxable_value]}
                      type="number"
                      label="Taxable value"
                      step="any"
                      required
                    />
                  </div>

                  <section class="border-rule space-y-related border-t pt-4">
                    <h4 class="text-base-content text-ui font-semibold">GST</h4>

                    <p :if={@line_edit_row.tax_rows == []} class="text-ink-muted text-ui">
                      Enter the applicable GST rates and amounts. Leave other tax fields blank.
                    </p>

                    <div
                      :for={tax <- editable_line_tax_rows(@line_edit_row)}
                      class="gap-block grid grid-cols-2"
                    >
                      <.input
                        field={@line_edit_form[tax_edit_field(tax.head, :rate)]}
                        type="number"
                        label={"#{tax.label} rate %"}
                        step="any"
                        required={@line_edit_row.tax_rows != []}
                      />
                      <.input
                        field={@line_edit_form[tax_edit_field(tax.head, :amount)]}
                        type="number"
                        label={"#{tax.label} amount"}
                        step="any"
                        required={@line_edit_row.tax_rows != []}
                      />
                    </div>
                  </section>

                  <p :if={@line_edit_error} id="sales-bill-line-edit-error" class="text-error text-ui">
                    {@line_edit_error}
                  </p>
                </.form>

                <:footer>
                  <.button type="button" variant="ghost" phx-click="close-posting-line">
                    Cancel
                  </.button>

                  <.button type="submit" form="sales-bill-line-edit-form">
                    Save changes
                  </.button>
                </:footer>
              </.modal>
            </section>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".SalesBillPostingReviewKeys">
            export default {
              mounted() {
                this.onKeydown = event => {
                  if (
                    this.el.dataset.navigationEnabled !== "true" ||
                    event.target.closest("dialog") !== this.el.closest("dialog") ||
                  (event.key !== "Escape" && window.localStorage.getItem("nila-shortcuts-enabled") === "false") ||
                    event.repeat || event.isComposing ||
                    document.querySelector(":popover-open") ||
                    event.target.closest("[role='tablist'], [role='combobox'], [role='listbox'], [role='slider']") ||
                    event.defaultPrevented ||
                    event.altKey ||
                    event.ctrlKey ||
                    event.metaKey ||
                    event.shiftKey ||
                    event.target.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])")
                  ) return

                  if (event.key === "Escape") {
                    event.preventDefault()
                    this.pushEvent("close-posting-review", {})
                    return
                  }
                  const item = event.key === "ArrowLeft"
                    ? this.el.dataset.previousItem
                    : event.key === "ArrowRight"
                      ? this.el.dataset.nextItem
                      : null

                  if (!item) return

                  event.preventDefault()
                  this.pushEvent("navigate-posting-review", {item})
                }

                window.addEventListener("keydown", this.onKeydown)
              },

              destroyed() {
                window.removeEventListener("keydown", this.onKeydown)
              }
            }
          </script>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".InvoiceFactsFocus">
            export default {
              mounted() {
                const field = this.el.dataset.focusField
                const target = field
                  ? this.el.querySelector(`[name="invoice_facts[${field}]"]`)
                  : this.el.querySelector("input, select, textarea")

                requestAnimationFrame(() => target?.focus())
              }
            }
          </script>
        </div>
      </section>

      <.evidence_overlay
        :if={(@evidence_open and @selected_invoice) && @selected_invoice["image_urls"] != []}
        id="sales-bill-evidence-overlay"
        images={@selected_invoice["image_urls"]}
        page={@evidence_page}
        title={@selected_invoice["invoice_number"] || "Invoice"}
        on_close="close-posting-evidence"
        on_page="posting-evidence-page"
      />
    </Layouts.app>
    """
  end
end
