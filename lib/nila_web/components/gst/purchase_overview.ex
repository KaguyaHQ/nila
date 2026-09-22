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
  attr :statement, :any, default: nil
  attr :fetching_2b, :boolean, default: false
  attr :fetch_2b_error, :any, default: nil
  attr :availability_hint, :any, default: nil

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
          <div class="gap-block flex flex-col p-6">
            <div class="space-y-related">
              <div class="gap-related flex flex-wrap items-center justify-between">
                <h3 class="text-ui font-medium">Purchase register</h3>

                <.button
                  id="purchase-import-excel"
                  phx-click="import-excel"
                  variant={if @books_present || @portal_present, do: "outline", else: "primary"}
                  disabled={!@can_edit || @signed_off?}
                >Import purchase Excel</.button>
              </div>

              <p :if={@books_present} id="purchase-books-totals" class="text-ui">
                <strong>{@overview.books_count}</strong>
                documents · <strong>{Workspace.money(@overview.books_tax)}</strong>
                GST
              </p>

              <p :if={!@books_present} class="text-ink-muted text-ui">Not imported</p>
            </div>

            <div class="space-y-related">
              <div :if={@books_present} class="gap-related flex flex-wrap items-center">
                <.text_link
                  id="purchase-register-link"
                  navigate={Workspace.list_path(@client.id, @period, "register", "")}
                >View purchase register</.text_link>
              </div>

              <div class="flex min-h-8 items-center">
                <.text_link
                  id="purchase-uploads-link"
                  navigate={~p"/gst/#{@client.id}/#{@period}/purchases/uploads"}
                >Upload history</.text_link>
              </div>
            </div>
          </div>

          <div class="border-rule gap-block flex flex-col border-t p-6 md:border-t-0 md:border-l">
            <div class="space-y-related">
              <div class="gap-related flex flex-wrap items-center justify-between">
                <h3 class="text-ui font-medium">GSTR-2B</h3>

                <div class="gap-related flex flex-wrap items-center">
                  <.button
                    variant={
                      if @portal_present || @statement_needs_import, do: "ghost", else: "outline"
                    }
                    id="purchase-fetch-2b"
                    phx-click="fetch-2b"
                    disabled={!@can_edit || @fetching_2b}
                    phx-disable-with="Fetching…"
                  >
                    <.icon :if={@portal_present} name="hero-arrow-path" class="size-4" /> {if @fetching_2b,
                      do: "Fetching GSTR-2B…",
                      else: if(@portal_present, do: "Refresh", else: "Fetch GSTR-2B")}
                  </.button>

                  <.action_menu
                    :if={@can_export && @statement && @statement.fetched_at}
                    id="purchase-2b-source-menu"
                    label="GSTR-2B source actions"
                  >
                    <:item
                      id="purchase-gstr2b-download"
                      label="Download source JSON"
                      icon="hero-arrow-down-tray"
                      href={~p"/gst/2b/statements/#{@statement.id}/download"}
                    />
                  </.action_menu>
                </div>
              </div>

              <p :if={@portal_present} id="purchase-portal-totals" class="text-ui">
                <strong>{@overview.portal_count}</strong>
                documents · <strong>{Workspace.money(@overview.portal_tax)}</strong>
                GST
              </p>

              <p :if={!@portal_present} class="text-ink-muted text-ui">Not imported</p>

              <p
                :if={@statement && @statement.fetched_at}
                id="purchase-2b-fetched-at"
                class="text-ink-muted text-ui"
              >
                Last fetched {fetched_at(@statement.fetched_at)}
              </p>

              <p :if={@availability_hint} id="purchase-2b-availability" class="text-ink-muted text-ui">
                {@availability_hint}
              </p>

              <p :if={@fetching_2b} id="purchase-2b-fetching" class="text-ink-muted text-ui">
                Fetching the latest GSTR-2B from the portal…
              </p>

              <p
                :if={@fetch_2b_error}
                id="purchase-2b-fetch-error"
                role="alert"
                class="text-error text-ui"
              >
                {@fetch_2b_error}
              </p>

              <p
                :if={@fetch_2b_error && @statement && @statement.fetched_at}
                id="purchase-2b-retained"
                class="text-ink-muted text-ui"
              >
                Your previously downloaded statement is still available.
              </p>
            </div>

            <div :if={@portal_present || @statement_needs_import} class="space-y-related">
              <div class="gap-related flex flex-wrap items-center">
                <.button
                  :if={@portal_present}
                  id="purchase-gstr2b-link"
                  variant={
                    if @books_present || @statement_needs_import, do: "outline", else: "primary"
                  }
                  navigate={Workspace.list_path(@client.id, @period, "gstr2b", "")}
                ><%= if @books_present do %>
                  View GSTR-2B
                <% else %>
                  Review {@overview.portal_count} GSTR-2B {if @overview.portal_count == 1,
                    do: "document",
                    else: "documents"}
                <% end %></.button>
                <.button
                  :if={@statement_needs_import}
                  id="purchase-use-2b"
                  phx-click="use-2b"
                  disabled={!@can_edit || @signed_off? || @processing}
                  phx-disable-with="Adding…"
                >{if @portal_present, do: "Update reconciliation", else: "Start reconciliation"}</.button>
              </div>
            </div>
          </div>
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
                    "Books comparison not available"

                  @books_present ->
                    "Purchases are ready. Import GSTR-2B to compare with supplier records."

                  true ->
                    "Import the purchase register and GSTR-2B to begin."
                end}
              </p>

              <p class="text-ink-muted text-ui">
                {if @portal_present && !@books_present,
                  do: "Import a purchase register to compare it with GSTR-2B.",
                  else:
                    "Matches and missing invoices can be identified once both sources are available."}
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
              <div
                :if={!@overview.treatment_recorded?}
                id="purchase-treatment-empty"
                class="space-y-related"
              >
                <p class="text-ui">No ITC treatments recorded yet.</p>

                <p class="text-ink-muted text-ui">
                  {if @portal_present,
                    do: "Review GSTR-2B to record decisions.",
                    else: "Record ITC treatment as you review purchase documents."}
                </p>
              </div>

              <dl
                :if={@overview.treatment_recorded?}
                id="purchase-treatment-totals"
                class="text-ui space-y-3"
              >
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

              <p :if={@overview.treatment_recorded?} class="text-ink-muted text-ui">
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

            <p :if={!@complete?} id="purchase-working-remainder" class="text-ink-muted text-ui">
              {cond do
                @processing ->
                  "Uploaded records are still being processed."

                @inputs_unresolved? ->
                  "An upload needs attention before reconciliation can finish."

                !@books_present && !@portal_present ->
                  "Purchase register and GSTR-2B not imported. Reconciliation hasn't been run."

                !@books_present ->
                  "Purchase register not imported. Reconciliation hasn't been run."

                !@portal_present ->
                  "GSTR-2B not imported. Reconciliation hasn't been run."

                @statement_needs_import ->
                  "The latest GSTR-2B has not been added to reconciliation."

                @overview.stale_count > 0 ->
                  "Source amounts changed. ITC treatment needs another review."

                @overview.remaining > 0 ->
                  "#{@overview.remaining} #{if @overview.remaining == 1, do: "item still needs", else: "items still need"} review."

                true ->
                  "ITC treatment is still undecided for #{Workspace.money(@overview.pending_tax)}."
              end}
            </p>

            <.button
              :if={@month && @can_export}
              id="purchase-workings-download"
              variant="soft"
              href={~p"/gst/#{@client.id}/#{@period}/purchases/workings.xlsx"}
            >{if @complete?, do: "Download working", else: "Download draft working"}</.button>
            <div>
              <.text_link
                id="purchase-gstr3b-link"
                navigate={~p"/gst/#{@client.id}/#{@period}/gstr3b"}
              >View GSTR-3B working →</.text_link>
            </div>

            <p :if={!@month} class="text-ink-muted text-ui">
              Import records to make the working available.
            </p>
          </div>
        </.card>
      </div>
    </section>
    """
  end

  defp fetched_at(time),
    do: time |> DateTime.add(19_800) |> Calendar.strftime("%d %b %Y at %H:%M IST")
end
