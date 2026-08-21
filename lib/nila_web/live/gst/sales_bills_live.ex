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

  defp remainder(packet) do
    excluded =
      Enum.map(packet.excluded, fn invoice ->
        invoice["invoice_number"] || invoice["buyer_name"] || "Unnumbered bill"
      end)

    failed = Enum.map(packet.failed_files, &TallyPacket.original_name/1)
    unread = Enum.map(packet.unread_pages, &"#{&1.file} · page #{&1.page}")

    excluded ++ failed ++ unread
  end

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

          <.download_button
            :if={@packet.invoices != []}
            href={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}/tally.xml"}
            id="sales-bills-download"
          >
            Download Tally XML
          </.download_button>
        </section>

        <section :if={remainder(@packet) != []} id="sales-bills-remainder" class="space-y-related">
          <h2 class="text-base-content text-h4 font-semibold">Not included</h2>
          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li :for={item <- remainder(@packet)} class="text-base-content text-ui py-3 font-medium">
              {item}
            </li>
          </ul>
        </section>

        <section :if={@packet.invoices != []} id="sales-bills-vouchers">
          <.data_table
            id="sales-bills-voucher-table"
            rows={@packet.invoices}
            row_id={fn invoice -> "sales-bill-#{invoice["id"] || invoice["invoice_number"]}" end}
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
          </.data_table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
