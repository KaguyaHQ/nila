defmodule NilaWeb.GstMonthLive do
  use NilaWeb, :live_view

  alias Nila.Gst.{ClientMonths, Resolutions}

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    case org && ClientMonths.get_by_period(org.id, client_id, period) do
      {:ok, client_month} ->
        {:ok,
         socket
         |> assign(:page_title, "GST · Breeze Tech · October 2025")
         |> assign(:client_id, client_month.client_id)
         |> assign(:period, client_month.period)
         |> assign(:rows, build_rows(client_month))
         |> assign(:summary, client_month.summary)
         |> assign(:stats, build_stats(client_month.summary))
         |> assign(:gstr3b, Resolutions.workings(client_month).gstr3b)
         |> assign(:selected_row, nil)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end

  defp build_rows(client_month) do
    client_month.register_rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> put_row_view(row, index, client_month) end)
  end

  defp put_row_view(row, index, client_month) do
    urls =
      row
      |> Map.get("images", [])
      |> Enum.map(fn path ->
        ~p"/gst/#{client_month.client_id}/#{client_month.period}/evidence/#{Path.basename(path)}"
      end)

    row
    |> Map.put("image_urls", urls)
    |> Map.put("dom_id", row_dom_id(row, index))
  end

  defp row_dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp row_dom_id(_row, index), do: "gst-row-idx-#{index}"

  @impl true
  def handle_event("select-row", %{"dom_id" => dom_id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1["dom_id"] == dom_id))
    {:noreply, assign(socket, :selected_row, row)}
  end

  def handle_event("close-evidence", _params, socket) do
    {:noreply, assign(socket, :selected_row, nil)}
  end

  defp build_stats(summary) do
    buckets = summary["buckets"] || %{}
    total = buckets |> Map.values() |> Enum.sum()
    matched = buckets["matched"] || 0

    %{
      invoices: total,
      matched: matched,
      need_decision: total - matched,
      matched_tax_paise: summary["matched_tax_paise"] || 0
    }
  end

  defp bucket_variant("matched"), do: "success"
  defp bucket_variant("needs_human"), do: "warning"
  defp bucket_variant("value_mismatch"), do: "error"
  defp bucket_variant(_), do: "info"

  defp attention?(row), do: row["bucket"] == "needs_human" or row["flags"] not in [nil, []]

  # Quiet matched rows recede; rows that need a human get a colored left edge
  # keyed to severity, so the eye lands on the pile without reading a word.
  defp row_accent(row) do
    cond do
      row["bucket"] == "needs_human" ->
        "border-l-2 border-l-warning bg-warning/[0.03]"

      row["bucket"] in ["value_mismatch", "in_2b_not_books", "in_books_not_2b"] ->
        "border-l-2 border-l-error/70 bg-error/[0.03]"

      row["flags"] not in [nil, []] ->
        "border-l-2 border-l-warning/60"

      true ->
        "opacity-60"
    end
  end

  defp row_note(row) do
    case row["flags"] do
      [%{"reason" => reason} | _] when is_binary(reason) and reason != "" -> reason
      _ -> row["recon_note"]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="gst-month-page" class="mx-auto max-w-6xl space-y-6">
        <.page_header eyebrow="GST" title="Breeze Tech · October 2025">
          The worked month, read-only. Every row is one tap from its scanned bill — matched
          lines sit quiet, the pile that needs a decision is flagged.
        </.page_header>

        <div id="gst-stats" class="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <.stat_card label="Invoices" value_id="gst-stat-invoices">
            {@stats.invoices}
          </.stat_card>
          <.stat_card label="Matched to 2B" value_id="gst-stat-matched">
            {@stats.matched}
          </.stat_card>
          <.link navigate={~p"/gst/#{@client_id}/#{@period}/exceptions"} id="gst-open-exceptions">
            <.stat_card label="Need a decision" value_id="gst-stat-need-decision">
              {@stats.need_decision}
            </.stat_card>
          </.link>
          <.stat_card label="ITC / matched tax" value_id="gst-stat-matched-tax" figure>
            {format_money(@stats.matched_tax_paise, prefix: "₹")}
          </.stat_card>
        </div>

        {gstr3b_panel(assigns)}

        <.data_table
          id="gst-register"
          rows={@rows}
          row_id={fn row -> row["dom_id"] end}
          row_click={fn row -> JS.push("select-row", value: %{dom_id: row["dom_id"]}) end}
          row_class={&row_accent/1}
          min_width="min-w-[880px]"
        >
          <:col :let={row} label="Inv No">
            <div class="flex items-center gap-2">
              <.icon
                :if={attention?(row)}
                name="hero-exclamation-triangle-mini"
                class="text-warning size-4 shrink-0"
              />
              <span class="font-medium">{row["invoice_number"] || "—"}</span>
            </div>
          </:col>
          <:col :let={row} label="Vendor">{row["vendor_name"]}</:col>
          <:col :let={row} label="Taxable" align="right">
            {format_money(row["taxable_paise"], prefix: "₹")}
          </:col>
          <:col :let={row} label="Tax total" align="right">
            {format_money(
              (row["cgst_paise"] || 0) + (row["sgst_paise"] || 0) + (row["igst_paise"] || 0),
              prefix: "₹"
            )}
          </:col>
          <:col :let={row} label="2B status">
            <.badge variant={bucket_variant(row["bucket"])}>{row["bucket_label"]}</.badge>
          </:col>
          <:col :let={row} label="Note" class="max-w-sm">
            <span
              :if={attention?(row)}
              class="text-base-content text-small"
            >
              {row_note(row)}
            </span>
            <span :if={!attention?(row)} class="text-base-content/35 text-fine">
              matched
            </span>
          </:col>
        </.data_table>
      </div>

      <.modal
        :if={@selected_row}
        id="gst-evidence-modal"
        title={evidence_title(@selected_row)}
        on_close="close-evidence"
        class="max-w-4xl"
      >
        <div class="grid gap-5 lg:grid-cols-[1fr_20rem]">
          <div id="gst-evidence-images" class="space-y-3">
            <img
              :for={url <- @selected_row["image_urls"]}
              src={url}
              alt="Scanned bill"
              class="border-base-300 rounded-box w-full border"
            />
            <div
              :if={@selected_row["image_urls"] == []}
              class="border-base-300 rounded-box text-base-content/60 text-small flex h-40 items-center justify-center border border-dashed"
            >
              No scanned bill — this line appears in GSTR-2B only.
            </div>
          </div>

          <div id="gst-evidence-why" class="space-y-4">
            <div>
              <div class="text-base-content/60 text-label font-medium uppercase">Vendor</div>
              <div class="text-base-content text-small mt-1 font-medium">
                {@selected_row["vendor_name"]}
              </div>
              <div :if={@selected_row["vendor_gstin"]} class="text-base-content/60 text-fine mt-0.5">
                {@selected_row["vendor_gstin"]}
              </div>
            </div>

            <div :if={@selected_row["recon_note"]}>
              <div class="text-base-content/60 text-label font-medium uppercase">Recon note</div>
              <p class="text-base-content text-small mt-1">{@selected_row["recon_note"]}</p>
            </div>

            <div :if={@selected_row["next_action"]}>
              <div class="text-base-content/60 text-label font-medium uppercase">Next action</div>
              <p class="text-base-content text-small mt-1">{@selected_row["next_action"]}</p>
            </div>

            <div :if={@selected_row["flags"] not in [nil, []]} class="space-y-2">
              <div class="text-base-content/60 text-label font-medium uppercase">Flags</div>
              <div
                :for={flag <- @selected_row["flags"]}
                class="bg-base-200/40 border-base-300 rounded-box border p-3"
              >
                <.badge variant={if(flag["severity"] == "error", do: "error", else: "warning")}>
                  {humanize_label(flag["code"])}
                </.badge>
                <p class="text-base-content/80 text-small mt-2">{flag["reason"]}</p>
              </div>
            </div>
          </div>
        </div>
      </.modal>
    </Layouts.app>
    """
  end

  # The month's ending: the assembled GSTR-3B. Liability (3.1a) comes from the
  # client's worked sales month when one exists; ITC (Table 4) from the 2B
  # reconciliation + confirmed blocks; 6.1 resolves them into cash payable.
  # When no sales month exists the liability side is honestly absent — the
  # panel shows the ITC half and says what's missing, never a fake ₹0 payable.
  defp gstr3b_panel(assigns) do
    ~H"""
    <div id="gst-3b-panel" class="border-base-300 rounded-box border">
      <div class="border-base-300 flex items-center justify-between border-b px-4 py-3">
        <div>
          <div class="text-base-content/60 text-label font-medium uppercase">GSTR-3B</div>
          <div class="text-base-content/50 text-fine mt-0.5">
            {if liability_missing?(@gstr3b),
              do: "ITC side assembled — outward liability needs the month's sales bills",
              else: "Assembled from the worked sales month and the 2B reconciliation"}
          </div>
        </div>
        <div :if={!liability_missing?(@gstr3b)} class="text-right">
          <div class="text-base-content/60 text-label font-medium uppercase">Cash payable</div>
          <div id="gst-3b-cash" class="text-base-content text-lead font-mono font-semibold">
            {money_paise(@gstr3b["setoff_61"]["cash_total"])}
          </div>
        </div>
      </div>

      <div class="grid gap-x-6 gap-y-2 px-4 py-3 sm:grid-cols-2">
        <div :if={!liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">3.1 Outward liability</div>
          <.gstr3b_line label="(a) Taxable supplies" heads={@gstr3b["liability_31"]["a"]} />
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>
        <div :if={liability_missing?(@gstr3b)} class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">3.1 Outward liability</div>
          <p class="text-base-content/50 text-small">
            No worked sales month for this period yet — upload the sales bills to derive
            GSTR-1 and complete the return.
          </p>
          <.gstr3b_line label="(d) Reverse charge" heads={@gstr3b["liability_31"]["d"]} />
        </div>

        <div class="space-y-1.5">
          <div class="text-base-content/40 text-fine uppercase">4. Eligible ITC</div>
          <.gstr3b_line label="A(3) Reverse charge credit" heads={@gstr3b["itc"]["rcm_4a3"]} />
          <.gstr3b_line label="A(5) All other ITC" heads={@gstr3b["itc"]["all_other_itc_4a5"]} />
          <.gstr3b_line
            label="B Reversed (confirmed blocks)"
            heads={sum_4b(@gstr3b["itc"])}
            negative
          />
          <.gstr3b_line label="C Net ITC" heads={@gstr3b["itc"]["net_itc_4c"]} strong />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :heads, :map, required: true
  attr :negative, :boolean, default: false
  attr :strong, :boolean, default: false

  defp gstr3b_line(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-3">
      <span class={[
        "text-small",
        (@strong && "text-base-content font-medium") || "text-base-content/70"
      ]}>
        {@label}
      </span>
      <span class={[
        "text-small font-mono",
        @negative && "text-error",
        !@negative && ((@strong && "text-base-content font-semibold") || "text-base-content/80")
      ]}>
        {if @negative, do: "−"}{money_paise(heads_total(@heads))}
      </span>
    </div>
    """
  end

  defp liability_missing?(gstr3b), do: gstr3b["liability_source"] == "missing"

  defp heads_total(heads),
    do: (heads["igst"] || 0) + (heads["cgst"] || 0) + (heads["sgst"] || 0)

  defp sum_4b(itc) do
    Nila.Gst.ItcPosition.sum_heads([itc["reversed_4b1"], itc["reversed_4b2"]])
  end

  # 3B figures keep paise — this is the return the firm files.
  defp money_paise(paise), do: Nila.Formatters.format_money_with_paise(paise || 0)

  defp evidence_title(row) do
    [row["invoice_number"], row["vendor_name"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> "Evidence"
      title -> title
    end
  end
end
