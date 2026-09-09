defmodule NilaWeb.Gst.SalesBillsLive do
  use NilaWeb, :live_view
  alias NilaWeb.Gst.{InvoiceWorkbench, SalesBillReview}

  import NilaWeb.Gst.SalesBillReview,
    except: [mount: 3, handle_params: 3, handle_event: 3, handle_info: 2]

  alias Nila.Gst.Sales.{Invoice, TallyPacket}

  @impl true
  defdelegate mount(params, session, socket), to: SalesBillReview

  @impl true
  def handle_params(%{"item" => source_id} = params, _uri, socket) do
    dump =
      Enum.find(socket.assigns.source_dumps, fn dump ->
        Enum.any?(dump.invoices || [], &(Invoice.source_id(&1) == source_id))
      end)

    if dump do
      scope = if params["review"] == "required", do: "needs_you", else: params["scope"] || "all"

      path =
        InvoiceWorkbench.path(
          socket.assigns.current_scope.current_org.id,
          socket.assigns.client.id,
          dump.period,
          source_id,
          scope,
          params["return_to"]
        )

      query = if params["period"], do: %{}, else: %{"batch" => socket.assigns.batch_ref}

      query =
        if params["view"] == "accounting", do: Map.put(query, "view", "accounting"), else: query

      path = if map_size(query) > 0, do: path <> "&" <> URI.encode_query(query), else: path
      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, push_navigate(socket, to: batch_home_path(socket))}
    end
  end

  def handle_params(params, uri, socket), do: SalesBillReview.handle_params(params, uri, socket)

  @impl true
  defdelegate handle_event(event, params, socket), to: SalesBillReview
  @impl true
  defdelegate handle_info(message, socket), to: SalesBillReview

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active_client={@client}
    >
      <div id="sales-bills-result" class="space-y-region mx-auto max-w-6xl">
        <.link
          navigate={~p"/sales-bills"}
          id="sales-bills-back"
          class="text-ink-muted text-ui inline-flex items-center gap-1 font-medium"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Sales bills
        </.link>

        <section :if={processing?(@processing_jobs)} id="sales-bills-processing">
          <div class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>

            <h1 class="text-base-content text-h2 font-semibold">
              Reading invoices
            </h1>

            <p class="text-ink-muted text-ui tabular-nums">
              {processing_source_label(@processing_jobs)}
            </p>
          </div>

          <div class="mt-section space-y-related max-w-2xl">
            <p
              id="sales-bills-processing-progress"
              class="text-base-content text-h4 font-semibold tabular-nums"
            >
              {processing_progress_label(@processing_jobs)}
            </p>

            <%= if progress = processing_invoice_progress(@processing_jobs) do %>
              <.progress_bar
                id="sales-bills-processing-bar"
                value={progress.done}
                max={max(progress.total, 1)}
              />
            <% end %>

            <p
              :if={processing_retry_label(@processing_jobs)}
              id="sales-bills-processing-retry"
              class="text-ui text-warning"
            >
              {processing_retry_label(@processing_jobs)}
            </p>

            <p class="text-ink-muted text-ui">
              You can leave this page — processing will continue.
            </p>
          </div>
        </section>

        <section
          :if={not processing?(@processing_jobs)}
          class="gap-region flex flex-col lg:flex-row lg:items-end lg:justify-between"
        >
          <div :if={@accounting_view?} class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>

            <h1 class="text-base-content text-h2 font-semibold">
              {batch_result_title(@packet, @required_mapping_invoices)}
            </h1>

            <p
              :if={
                ready_invoice_count(@packet, @required_mapping_invoices) == 0 and
                  (attention_invoice_count(@packet, @required_mapping_invoices) > 0 or
                     @packet.excluded != [])
              }
              class="text-body text-ink-muted tabular-nums"
            >
              {attention_summary(@packet, @required_mapping_invoices)}
            </p>

            <p
              :if={ready_invoice_count(@packet, @required_mapping_invoices) > 0}
              class="text-ink-muted text-lead tabular-nums"
            >
              {money(ready_totals(@packet, @required_mapping_invoices).taxable_paise)} taxable · {money(
                ready_totals(@packet, @required_mapping_invoices).tax_paise
              )} tax<span :if={@packet.excluded != []}> · {excluded_summary(@packet)}</span>
            </p>
          </div>

          <div :if={not @accounting_view?} class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>

            <h1 id="sales-bills-result-title" class="text-h3 font-semibold">
              {length(@packet.all_invoices)} {plural(length(@packet.all_invoices), "invoice")} processed
            </h1>

            <p class="text-ink-muted text-ui">
              {length(batch_gst_review_invoices(@packet))} {if length(
                                                                 batch_gst_review_invoices(@packet)
                                                               ) == 1, do: "needs", else: "need"} GST review
              <span :if={@packet.excluded != []}> · {excluded_summary(@packet)}</span>
            </p>
          </div>

          <div :if={not @accounting_view?} class="gap-block flex items-center">
            <.button
              :if={batch_gst_review_invoices(@packet) != []}
              id="sales-bills-review-gst"
              navigate={
                posting_review_path(
                  @client,
                  @batch_ref,
                  List.first(batch_gst_review_invoices(@packet)),
                  false,
                  false,
                  @source_dumps
                )
              }
            >
              Review {length(batch_gst_review_invoices(@packet))}
            </.button>

            <.button
              :for={period <- Enum.uniq(Enum.map(@source_dumps, & &1.period))}
              id={"sales-bills-open-period-#{period}"}
              variant="outline"
              navigate={~p"/gst/#{@client.id}/#{period}/sales"}
            >
              Open {Nila.Formatters.period_label(period)} working
            </.button>
          </div>

          <div :if={@accounting_view? && @packet.invoices != []} class="flex items-end gap-3">
            <div
              :if={@tally_company && @tally_jobs == []}
              id="sales-bills-tally-destination"
              class="flex items-end gap-3"
            >
              <p class="text-ink-muted text-ui pb-2">
                Tally · <span class="text-base-content font-semibold">{@tally_company.name}</span>
              </p>

              <.button
                :if={attention_invoice_count(@packet, @required_mapping_invoices) > 0}
                id="sales-bills-review-required"
                variant={
                  if(ready_invoice_count(@packet, @required_mapping_invoices) > 0,
                    do: "outline",
                    else: "primary"
                  )
                }
                navigate={
                  posting_review_path(
                    @client,
                    @batch_ref,
                    List.first(attention_invoices(@packet, @required_mapping_invoices)),
                    true,
                    true,
                    @source_dumps
                  )
                }
              >
                Review {attention_invoice_count(@packet, @required_mapping_invoices)}
              </.button>

              <.button
                :if={
                  ready_invoice_count(@packet, @required_mapping_invoices) > 0 or
                    @required_mapping_invoices == []
                }
                type="button"
                id="sales-bills-send-to-tally"
                phx-click="request-send-to-tally"
                disabled={not @tally_online? or not @tally_masters_available?}
              >
                Send to Tally
              </.button>
            </div>

            <div
              :if={tally_result(@tally_jobs, length(@packet.invoices)) == :sending}
              id="sales-bills-sending-to-tally"
              class="text-base-content text-ui flex items-center gap-2 font-semibold"
            >
              <.spinner tone="accent" label="Sending to Tally" /> Sending to Tally
            </div>

            <div
              :if={tally_result(@tally_jobs, length(@packet.invoices)) == :added}
              id="sales-bills-added-to-tally"
              class="flex items-center gap-3"
            >
              <p class="text-success text-ui font-semibold">Added to Tally</p>

              <.button
                type="button"
                id="sales-bills-ensure-tally"
                phx-click="ensure-tally"
                variant="outline"
              >
                Check Tally
              </.button>
            </div>

            <div
              :if={
                match?(
                  {:partial, _added, _total},
                  tally_result(@tally_jobs, length(@packet.invoices))
                )
              }
              id="sales-bills-partial-tally-result"
              class="space-y-related"
            >
              <p class="text-base-content text-ui font-semibold">
                {elem(tally_result(@tally_jobs, length(@packet.invoices)), 1)} of {elem(
                  tally_result(@tally_jobs, length(@packet.invoices)),
                  2
                )} added to Tally
              </p>

              <.button
                :if={retryable?(@tally_jobs) or missing_delivery_jobs?(@packet, @tally_jobs)}
                type="button"
                id="sales-bills-retry-tally"
                phx-click="request-send-to-tally"
                variant="outline"
                disabled={not @tally_online? or not @tally_masters_available?}
              >
                Try again
              </.button>

              <.button
                :if={verifiable?(@tally_jobs)}
                type="button"
                id="sales-bills-verify-tally"
                phx-click="verify-tally"
                variant="outline"
              >
                Check Tally
              </.button>
            </div>

            <.download_button
              :if={is_nil(@tally_company)}
              href={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}/tally.xml"}
              id="sales-bills-download"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download Tally XML
            </.download_button>
          </div>
        </section>

        <p :if={@send_error} id="sales-bills-send-error" class="text-error text-ui">
          {@send_error}
        </p>

        <section
          :if={not processing?(@processing_jobs) and @packet.failed_files != []}
          id="sales-bills-failed-files"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">Couldn't read</h2>

          <ul class="border-rule divide-rule divide-y border-y">
            <li
              :for={dump <- @packet.failed_files}
              id={"sales-bills-failed-file-#{dump.id}"}
              class="gap-block flex items-center justify-between py-3"
            >
              <span class="text-base-content text-ui font-medium">
                {TallyPacket.original_name(dump)}
              </span>

              <.button
                type="button"
                id={"sales-bills-retry-file-#{dump.id}"}
                phx-click="retry-failed-file"
                phx-value-dump-id={dump.id}
                variant="outline"
              >
                Try again
              </.button>
            </li>
          </ul>
        </section>

        <section
          :if={
            @accounting_view? and not processing?(@processing_jobs) and
              remainder(@packet, @tally_jobs) != []
          }
          id="sales-bills-remainder"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">
            {remainder_title(@packet, @tally_jobs, @send_holds)}
          </h2>

          <ul class="border-rule divide-rule divide-y border-y">
            <li
              :for={item <- remainder(@packet, @tally_jobs)}
              class="text-base-content text-ui py-3 font-medium"
            >
              {item}
            </li>
          </ul>
        </section>

        <section :if={@packet.all_invoices != []} id="sales-bills-vouchers">
          <div :if={@tally_company} class="gap-block mb-4 flex items-center">
            <.button
              id="sales-bills-invoice-mode"
              variant={if @accounting_view?, do: "ghost", else: "soft"}
              patch={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}"}
            >Invoices</.button>
            <.button
              id="sales-bills-accounting-mode"
              variant={if @accounting_view?, do: "soft", else: "ghost"}
              patch={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}?view=accounting"}
            >Accounting</.button>
          </div>

          <.data_table
            id="sales-bills-voucher-table"
            rows={batch_table_invoices(@packet)}
            row_id={fn invoice -> "sales-bill-#{invoice["id"] || invoice["invoice_number"]}" end}
            row_navigate={
              fn invoice ->
                batch_row_path(
                  @packet,
                  @client,
                  @batch_ref,
                  invoice,
                  @accounting_view?,
                  @source_dumps
                )
              end
            }
            row_class={fn invoice -> batch_row_class(@packet, invoice) end}
            row_label={
              fn invoice ->
                "Review invoice #{invoice["invoice_number"] || "without a number"}"
              end
            }
            mode="scan"
            min_width="min-w-[760px]"
          >
            <:col :let={invoice} label="Invoice" row_header>
              <span class="font-mono font-medium whitespace-nowrap">
                {invoice["invoice_number"] || "—"}
              </span>
            </:col>

            <:col :let={invoice} label="Date">
              <span class="whitespace-nowrap tabular-nums">
                {format_display_date(invoice["invoice_date"])}
              </span>
            </:col>

            <:col :let={invoice} label="Buyer">
              <span class="block max-w-64 truncate" title={invoice["buyer_name"]}>
                {invoice["buyer_name"] || "—"}
              </span>
            </:col>

            <:col :let={invoice} label="Taxable" align="right">
              {rupees(totals(invoice).taxable)}
            </:col>

            <:col :let={invoice} label="Tax" align="right">
              {rupees(totals(invoice).tax)}
            </:col>

            <:col :let={invoice} label="Status">
              <div :if={not @accounting_view?} id={"sales-bill-gst-#{invoice_id(invoice)}"}>
                <.badge variant={
                  if batch_gst_issues(@packet, invoice) == [], do: "neutral", else: "warning"
                }>
                  {cond do
                    excluded_invoice?(@packet, invoice) -> "Excluded"
                    batch_gst_issues(@packet, invoice) != [] -> "Needs review"
                    true -> "No open GST checks"
                  end}
                </.badge>

                <p
                  :for={issue <- Enum.take(batch_gst_issues(@packet, invoice), 1)}
                  class="text-ink-muted text-ui"
                >
                  {issue["message"]}
                </p>
              </div>

              <div :if={@accounting_view?}>
                <span id={"sales-bill-delivery-#{invoice_id(invoice)}"} class="whitespace-nowrap">
                  <.badge variant={
                    invoice_delivery(
                      invoice,
                      @tally_jobs,
                      @packet,
                      @send_holds,
                      @required_mapping_invoices
                    ).variant
                  }>
                    {invoice_delivery(
                      invoice,
                      @tally_jobs,
                      @packet,
                      @send_holds,
                      @required_mapping_invoices
                    ).label}
                  </.badge>
                </span>

                <p
                  :if={
                    invoice_attention_reason(
                      @packet,
                      @required_mapping_invoices,
                      @required_mapping_counts,
                      invoice
                    )
                  }
                  id={"sales-bill-attention-#{invoice_id(invoice)}"}
                  class="text-ink-muted text-ui mt-1 max-w-64 whitespace-normal"
                >
                  {invoice_attention_reason(
                    @packet,
                    @required_mapping_invoices,
                    @required_mapping_counts,
                    invoice
                  )}
                </p>
              </div>
            </:col>

            <:col :let={invoice} label="" align="right">
              <.action_menu
                :if={not invoice_frozen?(@tally_jobs, invoice, @packet.all_invoices)}
                id={"sales-bill-actions-#{invoice_id(invoice)}"}
                label={"Actions for invoice #{invoice["invoice_number"] || "without a number"}"}
              >
                <:item
                  :if={not Enum.member?(@packet.excluded, invoice)}
                  id={"sales-bill-remove-#{invoice_id(invoice)}"}
                  label="Exclude from working"
                  icon="hero-minus-circle"
                  on_click="remove-invoice"
                  value={invoice_id(invoice)}
                />
                <:item
                  :if={Enum.member?(@packet.excluded, invoice)}
                  id={"sales-bill-restore-#{invoice_id(invoice)}"}
                  label="Include in working"
                  icon="hero-arrow-uturn-left"
                  on_click="restore-invoice"
                  value={invoice_id(invoice)}
                />
              </.action_menu>
            </:col>
          </.data_table>
        </section>
      </div>

      <.modal
        :if={@confirming_tally_send}
        id="sales-bills-tally-warning-dialog"
        title={
          "#{length(@packet.warnings)} #{plural(length(@packet.warnings), "invoice")} still #{if(length(@packet.warnings) == 1, do: "needs", else: "need")} review"
        }
        on_close="cancel-send-to-tally"
        return_focus="#sales-bills-send-to-tally, #sales-bills-retry-tally"
      >
        <ul class="border-rule divide-rule divide-y border-y">
          <li :for={warning <- @packet.warnings} class="space-y-related py-3">
            <p class="text-base-content text-ui font-mono font-medium">
              {warning.invoice["invoice_number"] || "Unnumbered invoice"}
            </p>

            <p class="text-ink-muted text-ui">{review_reason(warning)}</p>
          </li>
        </ul>

        <:footer>
          <.button
            id="sales-bills-tally-warning-cancel"
            type="button"
            variant="ghost"
            phx-click="cancel-send-to-tally"
          >
            Cancel
          </.button>

          <.button
            id="sales-bills-tally-warning-confirm"
            type="button"
            phx-click="send-to-tally"
          >
            Send {length(@packet.invoices)} anyway
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end
end
