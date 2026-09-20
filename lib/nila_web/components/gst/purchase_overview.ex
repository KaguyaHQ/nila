defmodule NilaWeb.Components.Gst.PurchaseOverview do
  use NilaWeb, :html
  alias NilaWeb.Gst.PurchaseWorkspace, as: Workspace

  attr :client, :map, required: true
  attr :period, :string, required: true
  attr :overview, :map, required: true
  attr :books_present, :boolean, required: true
  attr :portal_present, :boolean, required: true
  attr :can_edit, :boolean, required: true
  attr :signed_off?, :boolean, required: true
  attr :can_export, :boolean, required: true
  attr :month, :any, required: true
  attr :processing, :boolean, required: true
  attr :inputs_unresolved?, :boolean, required: true
  attr :statement_needs_import, :boolean, required: true

  def overview(assigns) do
    assigns =
      assign(
        assigns,
        :complete?,
        assigns.books_present and assigns.portal_present and not assigns.processing and
          not assigns.statement_needs_import and not assigns.inputs_unresolved? and
          assigns.overview.remaining == 0 and assigns.overview.pending_tax == 0 and
          assigns.overview.stale_count == 0
      )

    ~H"""
    <section id="purchase-overview" class="space-y-block">
      <.card padding="none">
        <.card_header title="Purchase data" />
        <div class="grid md:grid-cols-2">
          <div class="space-y-block p-6">
            <div class="gap-block flex flex-wrap items-center justify-between">
              <h3 class="text-ui font-medium">Purchase register</h3>

              <.button
                id="purchase-import-excel"
                phx-click="import-excel"
                variant={if @books_present, do: "soft", else: "primary"}
                disabled={!@can_edit || @signed_off?}
              >Import purchase Excel</.button>
            </div>

            <p :if={@books_present} id="purchase-books-totals" class="text-ui">
              <strong>{@overview.books_count}</strong>
              documents · <strong>{Workspace.money(@overview.books_tax)}</strong>
              GST
            </p>

            <p :if={!@books_present} class="text-ink-muted text-ui">Not imported</p>

            <.text_link
              :if={@books_present}
              id="purchase-register-link"
              navigate={Workspace.list_path(@client.id, @period, "register", "")}
            >View purchase register</.text_link>
            <.text_link
              id="purchase-uploads-link"
              navigate={~p"/gst/#{@client.id}/#{@period}/purchases/uploads"}
            >Uploads</.text_link>
            <p :if={!@books_present} class="text-ink-muted text-ui">
              Import the client's records to compare with GSTR-2B.
            </p>
          </div>

          <div class="border-rule space-y-block border-t p-6 md:border-t-0 md:border-l">
            <div class="gap-block flex flex-wrap items-center justify-between">
              <h3 class="text-ui font-medium">GSTR-2B</h3>

              <.button
                variant="soft"
                id="purchase-fetch-2b"
                navigate={~p"/gst/2b?#{%{client_id: @client.id, period: @period}}"}
              >{if @portal_present, do: "Refresh GSTR-2B", else: "Fetch GSTR-2B"}</.button>
            </div>

            <p :if={@portal_present} id="purchase-portal-totals" class="text-ui">
              <strong>{@overview.portal_count}</strong>
              documents · <strong>{Workspace.money(@overview.portal_tax)}</strong>
              GST
            </p>

            <p :if={!@portal_present} class="text-ink-muted text-ui">Not imported</p>

            <.text_link
              :if={@portal_present}
              id="purchase-gstr2b-link"
              navigate={Workspace.list_path(@client.id, @period, "gstr2b", "")}
            >View GSTR-2B</.text_link>
            <.button
              :if={@statement_needs_import}
              id="purchase-use-2b"
              phx-click="use-2b"
              disabled={!@can_edit || @signed_off? || @processing}
              phx-disable-with="Adding…"
            >{if @portal_present, do: "Update reconciliation", else: "Start reconciliation"}</.button>
          </div>
        </div>

        <div class="border-rule border-t px-6 py-3">
          <.context_text>
            Imported source totals. Credit notes reduce GST; corrections remain in the working.
          </.context_text>
        </div>
      </.card>

      <div class="gap-block grid xl:grid-cols-[minmax(0,1fr)_280px]">
        <div class="space-y-block min-w-0">
          <.card padding="none">
            <.card_header title="Reconciliation">
              <:actions>
                <span :if={@complete?} id="purchase-review-complete" class="text-success text-ui">No outstanding checks</span>
                <span
                  :if={@books_present && @portal_present && @overview.remaining > 0}
                  id="purchase-review-count"
                  class="text-ui"
                >
                  {@overview.remaining} {if @overview.remaining == 1,
                    do: "item needs",
                    else: "items need"} review
                </span>
              </:actions>
            </.card_header>

            <div :if={!@books_present || !@portal_present} class="space-y-block p-6">
              <p id="purchase-comparison-pending" class="text-ui font-medium">
                {cond do
                  @portal_present ->
                    "GSTR-2B is ready. Import purchases to compare with books."

                  @books_present ->
                    "Purchases are ready. Import GSTR-2B to compare with supplier records."

                  true ->
                    "Import the purchase register and GSTR-2B to begin."
                end}
              </p>

              <p class="text-ink-muted text-ui">
                Matches and missing invoices can be identified once both sources are available.
              </p>
            </div>

            <div :if={@books_present && @portal_present} class="p-4">
              <.data_table
                id="purchase-reconciliation"
                rows={@overview.buckets}
                mode="scan"
                surface="ghost"
              >
                <:col :let={row} label="Status" row_header>
                  <.link
                    :if={row.count > 0 && row.id == "matched"}
                    id={"purchase-summary-#{row.id}"}
                    navigate={Workspace.list_path(@client.id, @period, row.id, "")}
                    class="text-base-content hover:underline"
                  >{row.label}</.link>
                  <.text_link
                    :if={row.count > 0 && row.id != "matched"}
                    id={"purchase-summary-#{row.id}"}
                    navigate={Workspace.list_path(@client.id, @period, row.id, "")}
                  >{row.label} →</.text_link> <span :if={row.count == 0}>{row.label}</span>
                </:col>

                <:col :let={row} label="Items" align="right">{row.count}</:col>

                <:col :let={row} label="Purchase GST" align="right">
                  {if row.count == 0 || row.id == "2b_only", do: "—", else: Workspace.money(row.books)}
                </:col>

                <:col :let={row} label="GSTR-2B GST" align="right">
                  {if row.count == 0 || row.id == "books_only",
                    do: "—",
                    else: Workspace.money(row.portal)}
                </:col>
              </.data_table>
            </div>

            <div
              :if={@books_present && @portal_present}
              class="border-rule gap-block flex flex-wrap items-center justify-between border-t px-6 py-4"
            >
              <p class="text-ink-muted text-ui">
                Groups can contain multiple documents. ITC checks are reviewed separately.
              </p>

              <.button
                :if={@overview.first_review}
                id="purchase-review-all"
                navigate={
                  Workspace.review_path(
                    @client.id,
                    @period,
                    @overview.first_review.id,
                    "needs_review",
                    ""
                  )
                }
              >Review {@overview.remaining} {if @overview.remaining == 1, do: "item", else: "items"}</.button>
            </div>
          </.card>

          <.card padding="none">
            <.card_header title="ITC treatment" />
            <div class="space-y-block p-6">
              <dl id="purchase-treatment-totals" class="text-ui space-y-3">
                <div class="flex justify-between gap-4">
                  <dt>Claim in this month</dt><dd>{Workspace.money(@overview.claim_tax)}</dd>
                </div>

                <div class="flex justify-between gap-4">
                  <dt>Claim later</dt><dd>{Workspace.money(@overview.later_tax)}</dd>
                </div>

                <div class="flex justify-between gap-4">
                  <dt>Excluded from ITC</dt><dd>{Workspace.money(@overview.excluded_tax)}</dd>
                </div>

                <div :if={@overview.pending_tax > 0} class="flex justify-between gap-4">
                  <dt>Needs a decision</dt><dd>{Workspace.money(@overview.pending_tax)}</dd>
                </div>
              </dl>

              <p
                :if={@overview.stale_count > 0}
                id="purchase-stale-treatment"
                class="text-ui text-warning"
              >
                Source amounts changed for {@overview.stale_count} {if @overview.stale_count == 1,
                  do: "invoice",
                  else: "invoices"}. Review their ITC treatment.
              </p>

              <p class="text-ink-muted text-ui">
                These are recorded treatment decisions. Matching alone does not claim credit.
              </p>

              <.text_link
                :if={@overview.books_count + @overview.portal_count > 0}
                id="purchase-treatment-link"
                navigate={Workspace.list_path(@client.id, @period, "treatment", "")}
              >View ITC treatment</.text_link>
              <.text_link
                :if={@overview.carried_count > 0}
                id="purchase-carried-link"
                navigate={Workspace.list_path(@client.id, @period, "carried", "")}
              >Review {@overview.carried_count} carried {if @overview.carried_count == 1,
                do: "credit",
                else: "credits"} →</.text_link>
            </div>
          </.card>
        </div>

        <.card padding="none" class="self-start">
          <.card_header title="ITC working" />
          <div class="space-y-block p-6">
            <p id="purchase-working-status" class="text-ui">
              {if @complete?, do: "Working available for senior review", else: "Draft working"}
            </p>

            <p class="text-ink-muted text-ui">
              Includes source records, comparisons and recorded decisions. Outstanding checks remain visible.
            </p>

            <.button
              :if={@month && @can_export}
              id="purchase-workings-download"
              variant="soft"
              href={~p"/gst/#{@client.id}/#{@period}/purchases/workings.xlsx"}
            >{if @complete?, do: "Download working", else: "Download draft working"}</.button>
            <.text_link id="purchase-gstr3b-link" navigate={~p"/gst/#{@client.id}/#{@period}/gstr3b"}>View GSTR-3B</.text_link>
            <p :if={!@month} class="text-ink-muted text-ui">
              Import records to make the working available.
            </p>
          </div>
        </.card>
      </div>
    </section>
    """
  end
end
