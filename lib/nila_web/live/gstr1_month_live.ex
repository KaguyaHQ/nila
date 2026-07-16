defmodule NilaWeb.Gstr1MonthLive do
  use NilaWeb, :live_view

  alias Nila.Gst.SalesMonths
  alias Nila.Repo

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case org && SalesMonths.get_by_period(org.id, client_id, period) do
      {:ok, sales_month} ->
        sales_month = Repo.preload(sales_month, :client)

        {:ok,
         socket
         |> assign(:page_title, "GSTR-1 · #{sales_month.client.name} · #{period}")
         |> assign(:sales_month, sales_month)
         |> assign(:invoices, build_invoices(sales_month))
         |> assign(:issues_by_invoice, Enum.group_by(sales_month.issues, & &1["invoice"]))
         |> assign(:selected_invoice, nil)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That sales month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end

  defp build_invoices(sales_month) do
    Enum.map(sales_month.invoices, fn invoice ->
      Map.put(invoice, "image_urls", image_urls(invoice, sales_month))
    end)
  end

  defp image_urls(invoice, sales_month) do
    case invoice["page"] do
      page when is_integer(page) ->
        basename = "page_" <> String.pad_leading(Integer.to_string(page), 2, "0") <> ".png"

        [
          ~p"/gstr1/#{sales_month.client_id}/#{sales_month.period}/evidence/#{basename}"
        ]

      _ ->
        []
    end
  end

  @impl true
  def handle_event("select-invoice", %{"inum" => inum}, socket) do
    invoice = Enum.find(socket.assigns.invoices, &(&1["invoice_number"] == inum))
    {:noreply, assign(socket, :selected_invoice, invoice)}
  end

  def handle_event("close-evidence", _params, socket) do
    {:noreply, assign(socket, :selected_invoice, nil)}
  end

  defp invoice_issues(issues_by_invoice, invoice) do
    issues_by_invoice[invoice["invoice_number"]] || []
  end

  defp invoice_taxable(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.map(&(&1["taxable_value"] || 0))
    |> Enum.sum()
  end

  defp invoice_tax(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.map(fn line ->
      (line["cgst_amount"] || 0) + (line["sgst_amount"] || 0) + (line["igst_amount"] || 0)
    end)
    |> Enum.sum()
  end

  defp severity_variant("error"), do: "error"
  defp severity_variant(_), do: "warning"

  defp rupees(amount) when is_number(amount) do
    Nila.Formatters.format_money_with_paise(round(amount * 100))
  end

  defp rupees(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="gstr1-month-page" class="mx-auto max-w-6xl space-y-6">
        <.page_header
          eyebrow="GSTR-1"
          title={"#{@sales_month.client.name} · #{@sales_month.period}"}
        >
          The outward month as Nila derived it — every sales invoice, its validation
          issues, and the portal-shaped return ready for review.
        </.page_header>

        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="text-base-content/60 text-small">
            {length(@invoices)} invoices ·
            <span class={[
              length(@sales_month.issues) > 0 && "text-warning",
              length(@sales_month.issues) == 0 && "text-base-content/60"
            ]}>
              {length(@sales_month.issues)} validation issues
            </span>
          </div>
          <.button
            id="gstr1-download-json"
            href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
            variant="primary"
            size="sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Portal JSON
          </.button>
        </div>

        <.data_table
          id="gstr1-invoices"
          rows={@invoices}
          row_id={fn invoice -> "gstr1-inv-#{invoice["invoice_number"]}" end}
          row_click={
            fn invoice -> JS.push("select-invoice", value: %{inum: invoice["invoice_number"]}) end
          }
          min_width="min-w-[720px]"
        >
          <:col :let={invoice} label="Inv No">
            <div class="flex items-center gap-2">
              <.icon
                :if={invoice_issues(@issues_by_invoice, invoice) != []}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{invoice["invoice_number"] || "—"}</span>
            </div>
          </:col>
          <:col :let={invoice} label="Date">{invoice["invoice_date"] || "—"}</:col>
          <:col :let={invoice} label="Buyer">{invoice["buyer_name"] || "—"}</:col>
          <:col :let={invoice} label="Buyer GSTIN">
            <span class="text-fine font-mono">{invoice["buyer_gstin"] || "—"}</span>
          </:col>
          <:col :let={invoice} label="Taxable" align="right">
            {rupees(invoice_taxable(invoice))}
          </:col>
          <:col :let={invoice} label="Tax" align="right">{rupees(invoice_tax(invoice))}</:col>
          <:col :let={invoice} label="Issues">
            <span
              :if={invoice_issues(@issues_by_invoice, invoice) != []}
              class="text-small text-warning"
            >
              {length(invoice_issues(@issues_by_invoice, invoice))}
            </span>
            <span
              :if={invoice_issues(@issues_by_invoice, invoice) == []}
              class="text-base-content/35 text-fine"
            >
              clean
            </span>
          </:col>
        </.data_table>
      </div>

      <.modal
        :if={@selected_invoice}
        id="gstr1-evidence-modal"
        title={@selected_invoice["invoice_number"] || "Invoice"}
        on_close="close-evidence"
        class="max-w-4xl"
      >
        <div class="grid gap-5 lg:grid-cols-[1fr_20rem]">
          <div id="gstr1-evidence-images" class="space-y-3">
            <img
              :for={url <- @selected_invoice["image_urls"]}
              src={url}
              alt="Scanned sales bill"
              class="border-base-300 rounded-box w-full border"
            />
            <div
              :if={@selected_invoice["image_urls"] == []}
              class="border-base-300 rounded-box text-base-content/60 text-small flex h-40 items-center justify-center border border-dashed"
            >
              No page image for this invoice.
            </div>
          </div>

          <div class="space-y-4">
            <div>
              <div class="text-base-content/60 text-label font-medium uppercase">Buyer</div>
              <div class="text-base-content text-small mt-1 font-medium">
                {@selected_invoice["buyer_name"] || "—"}
              </div>
              <div class="text-base-content/60 text-fine mt-0.5 font-mono">
                {@selected_invoice["buyer_gstin"] || "—"}
              </div>
            </div>

            <div
              :if={invoice_issues(@issues_by_invoice, @selected_invoice) != []}
              class="space-y-2"
            >
              <div class="text-base-content/60 text-label font-medium uppercase">Issues</div>
              <div
                :for={issue <- invoice_issues(@issues_by_invoice, @selected_invoice)}
                class="bg-base-200/40 border-base-300 rounded-box border p-3"
              >
                <.badge variant={severity_variant(issue["severity"])}>
                  {humanize_label(issue["code"])}
                </.badge>
                <p class="text-base-content/80 text-small mt-2">{issue["message"]}</p>
              </div>
            </div>
          </div>
        </div>
      </.modal>
    </Layouts.app>
    """
  end
end
