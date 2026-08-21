defmodule NilaWeb.Gst.SalesBillsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Sales.TallyPacket

  @impl true
  def mount(%{"client_id" => client_id, "batch_ref" => batch_ref}, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, dumps} <- TallyPacket.fetch(org_id, client_id, batch_ref) do
      {:ok,
       socket
       |> assign(:page_title, "Sales bills")
       |> assign(:client, client)
       |> assign(:batch_ref, batch_ref)
       |> assign(:packet, TallyPacket.prepare(dumps))}
    else
      _not_found ->
        {:ok,
         socket
         |> put_flash(:error, "That sales packet could not be found.")
         |> push_navigate(to: ~p"/sales-bills")}
    end
  end

  defp totals(invoice), do: Nila.Gst.Sales.Gstr1.extracted_totals(invoice)

  defp rupees(value) when is_number(value),
    do: Nila.Formatters.format_money_with_paise(round(value * 100))

  defp rupees(_value), do: "—"

  defp money(paise), do: Nila.Formatters.format_money_with_paise(paise)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="sales-bills-result" class="space-y-region mx-auto max-w-6xl">
        <.link
          navigate={~p"/sales-bills"}
          id="sales-bills-back"
          class="text-ink-muted text-ui inline-flex items-center gap-1 font-medium"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Sales bills
        </.link>

        <section class="gap-region flex flex-col lg:flex-row lg:items-end lg:justify-between">
          <div class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>
            <h1 class="font-display text-base-content text-statement font-normal">
              <%= case length(@packet.invoices) do %>
                <% 0 -> %>
                  No sales vouchers ready
                <% 1 -> %>
                  1 sales voucher ready
                <% count -> %>
                  {count} sales vouchers ready
              <% end %>
            </h1>
            <p :if={@packet.invoices != []} class="text-ink-muted text-lead tabular-nums">
              {money(@packet.taxable_paise)} taxable · {money(@packet.tax_paise)} tax
            </p>
          </div>

          <.button
            :if={@packet.invoices != []}
            href={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}/tally.xml"}
            id="sales-bills-download"
          >
            Download Tally XML
          </.button>
        </section>

        <section :if={@packet.excluded != []} id="sales-bills-excluded" class="space-y-related">
          <h2 class="text-base-content text-h4 font-semibold">
            {length(@packet.excluded)} {if(length(@packet.excluded) == 1,
              do: "bill was",
              else: "bills were"
            )} not included
          </h2>
          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li
              :for={invoice <- @packet.excluded}
              class="text-ui flex items-center justify-between gap-4 py-3"
            >
              <span class="text-base-content font-medium">
                {invoice["invoice_number"] || "Unnumbered bill"}
              </span>
              <span class="text-ink-muted truncate">{invoice["buyer_name"] || "—"}</span>
            </li>
          </ul>
        </section>

        <section
          :if={@packet.failed_files != []}
          id="sales-bills-failed-files"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">
            {length(@packet.failed_files)} {if(length(@packet.failed_files) == 1,
              do: "file was",
              else: "files were"
            )} not included
          </h2>
          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li :for={dump <- @packet.failed_files} class="text-base-content text-ui py-3 font-medium">
              {TallyPacket.original_name(dump)}
            </li>
          </ul>
        </section>

        <section
          :if={@packet.unread_pages != []}
          id="sales-bills-unread-pages"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">
            {length(@packet.unread_pages)} {if(length(@packet.unread_pages) == 1,
              do: "page was",
              else: "pages were"
            )} not included
          </h2>
          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li :for={item <- @packet.unread_pages} class="text-base-content text-ui py-3">
              {item.file} · page {item.page}
            </li>
          </ul>
        </section>

        <section :if={@packet.invoices != []} id="sales-bills-vouchers" class="space-y-block">
          <h2 class="text-base-content text-h4 font-semibold">Prepared vouchers</h2>
          <.data_table
            id="sales-bills-voucher-table"
            rows={@packet.invoices}
            row_id={fn invoice -> "sales-bill-#{invoice["id"] || invoice["invoice_number"]}" end}
            mode="scan"
            min_width="min-w-[920px]"
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
            <:col :let={invoice} label="Customer">
              <span class="block max-w-64 truncate" title={invoice["buyer_name"]}>
                {invoice["buyer_name"] || "—"}
              </span>
            </:col>
            <:col :let={invoice} label="GSTIN">
              <span class="font-mono whitespace-nowrap">{invoice["buyer_gstin"] || "—"}</span>
            </:col>
            <:col :let={invoice} label="POS">
              <span class="whitespace-nowrap">{invoice["place_of_supply"] || "—"}</span>
            </:col>
            <:col :let={invoice} label="Taxable" align="right">
              {rupees(totals(invoice).taxable)}
            </:col>
            <:col :let={invoice} label="Tax" align="right">
              {rupees(totals(invoice).tax)}
            </:col>
          </.data_table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
