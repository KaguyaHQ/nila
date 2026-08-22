defmodule NilaWeb.Gst.SalesBillsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Sales.TallyPacket
  alias Nila.{TallyDevices, TallyJobs}

  @impl true
  def mount(%{"client_id" => client_id, "batch_ref" => batch_ref}, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, dumps} <- TallyPacket.fetch(org_id, client_id, batch_ref) do
      if connected?(socket), do: TallyJobs.subscribe_org(org_id)

      company = org_id |> TallyDevices.list_open_companies(client.id) |> List.first()
      source_prefix = company && tally_source_prefix(batch_ref, company.id)

      {:ok,
       socket
       |> assign(:page_title, "Sales bills")
       |> assign(:client, client)
       |> assign(:batch_ref, batch_ref)
       |> assign(:packet, TallyPacket.prepare(dumps))
       |> assign(:tally_company, company)
       |> assign(:tally_source_prefix, source_prefix)
       |> assign(:tally_jobs, list_tally_jobs(org_id, source_prefix))
       |> assign(:send_error, nil)}
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
  def handle_event("send-to-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id
    company = socket.assigns.tally_company

    with %{} <- company,
         {:ok, company} <-
           TallyDevices.get_open_company(org_id, company.id, socket.assigns.client.id),
         :ok <- TallyPrime.validate_company_gstin(company, socket.assigns.client.gstin),
         {:ok, items} <-
           TallyPrime.build_items_for_company(
             %{active_invoices: socket.assigns.packet.invoices},
             company.name
           ),
         {ready, blocked} <- partition_ready_items(company.id, items),
         {:ok, _jobs} <-
           TallyJobs.enqueue_vouchers(company, ready,
             source_prefix: socket.assigns.tally_source_prefix
           ) do
      {:noreply,
       socket
       |> assign(:tally_company, company)
       |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.tally_source_prefix))
       |> assign(:send_error, missing_ledgers_message(blocked))}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:tally_company, nil)
         |> assign(:send_error, "Tally is no longer connected. Download the XML instead.")}

      {:error, {:incompatible_voucher_numbering, issues}} ->
        {:noreply, assign(socket, :send_error, voucher_numbering_error(issues))}

      {:error, :tally_company_gstin_missing} ->
        {:noreply,
         assign(
           socket,
           :send_error,
           "This Tally company has no GSTIN. Configure GST in TallyPrime, sync it, then retry."
         )}

      {:error, {:tally_company_gstin_mismatch, tally_gstin, client_gstin}} ->
        {:noreply,
         assign(
           socket,
           :send_error,
           "This Tally company belongs to GSTIN #{tally_gstin}, not #{client_gstin}."
         )}

      _error ->
        {:noreply, assign(socket, :send_error, "Nila could not send these vouchers to Tally.")}
    end
  end

  def handle_event("verify-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyJobs.verify_indeterminate_by_source_prefix(
           org_id,
           socket.assigns.tally_source_prefix
         ) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.tally_source_prefix))
         |> assign(:send_error, nil)}

      _ ->
        {:noreply, assign(socket, :send_error, "Nila could not verify these vouchers in Tally.")}
    end
  end

  def handle_event("ensure-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyJobs.ensure_succeeded_by_source_prefix(
           org_id,
           socket.assigns.tally_source_prefix
         ) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.tally_source_prefix))
         |> assign(:send_error, nil)}

      _ ->
        {:noreply, assign(socket, :send_error, "Nila could not check these vouchers in Tally.")}
    end
  end

  defp voucher_numbering_error(issues) do
    types = issues |> Enum.map(& &1.voucher_type) |> Enum.uniq() |> Enum.join(", ")

    "#{types} voucher numbering in Tally must be Manual or Automatic (Manual Override). Change it in Tally, sync the company, then retry."
  end

  @impl true
  def handle_info(:tally_jobs_changed, socket) do
    {:noreply,
     assign(
       socket,
       :tally_jobs,
       list_tally_jobs(
         socket.assigns.current_scope.current_org.id,
         socket.assigns.tally_source_prefix
       )
     )}
  end

  defp remainder(packet, tally_jobs) do
    excluded =
      Enum.map(packet.excluded, fn invoice ->
        invoice["invoice_number"] || invoice["buyer_name"] || "Unnumbered bill"
      end)

    failed = Enum.map(packet.failed_files, &TallyPacket.original_name/1)
    unread = Enum.map(packet.unread_pages, &"#{&1.file} · page #{&1.page}")

    not_added =
      tally_jobs
      |> Enum.filter(&(&1.status in ["failed", "indeterminate"]))
      |> Enum.map(&(&1.payload["invoice_number"] || "Unnumbered bill"))

    job_invoice_numbers = MapSet.new(tally_jobs, & &1.payload["invoice_number"])

    missing_jobs =
      packet.invoices
      |> Enum.map(& &1["invoice_number"])
      |> Enum.reject(&MapSet.member?(job_invoice_numbers, &1))

    Enum.uniq(excluded ++ failed ++ unread ++ not_added ++ missing_jobs)
  end

  defp list_tally_jobs(_org_id, nil), do: []

  defp list_tally_jobs(org_id, source_prefix),
    do: TallyJobs.list_by_source_prefix(org_id, source_prefix)

  defp partition_ready_items(company_id, items) do
    missing =
      company_id
      |> Nila.TallySync.missing_ledgers(Enum.flat_map(items, & &1.ledger_names))
      |> MapSet.new(&String.downcase/1)

    Enum.reduce(items, {[], []}, fn item, {ready, blocked} ->
      missing_for_item =
        Enum.filter(item.ledger_names, &MapSet.member?(missing, String.downcase(&1)))

      creatable = item.party_ledger && String.downcase(item.party_ledger.name)
      missing_for_item = Enum.reject(missing_for_item, &(String.downcase(&1) == creatable))

      if missing_for_item == [] do
        {[item | ready], blocked}
      else
        {ready, [Map.put(item, :missing_ledgers, missing_for_item) | blocked]}
      end
    end)
    |> then(fn {ready, blocked} -> {Enum.reverse(ready), Enum.reverse(blocked)} end)
  end

  defp missing_ledgers_message([]), do: nil

  defp missing_ledgers_message(blocked) do
    invoices = Enum.map_join(blocked, ", ", & &1.invoice_number)

    ledgers =
      blocked
      |> Enum.flat_map(& &1.missing_ledgers)
      |> Enum.uniq()
      |> Enum.join(", ")

    "Held back #{length(blocked)} #{plural(length(blocked), "voucher")} (#{invoices}). " <>
      "Resolve the missing Tally ledgers, sync the company, then retry: #{ledgers}."
  end

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"

  defp tally_source_prefix(batch_ref, company_id) do
    batch_key =
      :crypto.hash(:sha256, batch_ref)
      |> Base.url_encode64(padding: false)

    "sales-bills:#{batch_key}:company:#{company_id}:voucher:"
  end

  defp sending_to_tally?(jobs), do: Enum.any?(jobs, &(&1.status in ["pending", "running"]))

  defp tally_result([], _expected_count), do: nil

  defp tally_result(jobs, expected_count) do
    added = Enum.count(jobs, &(&1.status == "succeeded"))
    finished = Enum.count(jobs, &(&1.status in ["succeeded", "failed", "indeterminate"]))

    cond do
      sending_to_tally?(jobs) -> :sending
      added == expected_count and length(jobs) == expected_count -> :added
      finished == length(jobs) -> {:partial, added, expected_count}
      true -> :sending
    end
  end

  defp retryable?(jobs),
    do:
      Enum.any?(jobs, &(&1.status == "failed")) and
        Enum.all?(jobs, &(&1.status != "indeterminate"))

  defp verifiable?(jobs), do: Enum.any?(jobs, &(&1.status == "indeterminate"))

  defp missing_delivery_jobs?(packet, jobs), do: length(jobs) < length(packet.invoices)

  defp remainder_title(jobs) do
    if Enum.any?(jobs, &(&1.status in ["failed", "indeterminate"])),
      do: "Not added to Tally",
      else: "Not included"
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

          <.button
            :if={(@packet.invoices != [] and @tally_company) && @tally_jobs == []}
            type="button"
            id="sales-bills-send-to-tally"
            phx-click="send-to-tally"
          >
            Send to Tally
          </.button>

          <div
            :if={
              @packet.invoices != [] and
                tally_result(@tally_jobs, length(@packet.invoices)) == :sending
            }
            id="sales-bills-sending-to-tally"
            class="text-base-content text-ui flex items-center gap-2 font-semibold"
          >
            <.spinner tone="accent" label="Sending to Tally" /> Sending to Tally
          </div>

          <div
            :if={
              @packet.invoices != [] and
                tally_result(@tally_jobs, length(@packet.invoices)) == :added
            }
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
              phx-click="send-to-tally"
              variant="outline"
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
            :if={@packet.invoices != [] and is_nil(@tally_company)}
            href={~p"/sales-bills/#{@client.id}/batch/#{@batch_ref}/tally.xml"}
            id="sales-bills-download"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download Tally XML
          </.download_button>
        </section>

        <p :if={@send_error} id="sales-bills-send-error" class="text-error text-ui">
          {@send_error}
        </p>

        <section
          :if={remainder(@packet, @tally_jobs) != []}
          id="sales-bills-remainder"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">{remainder_title(@tally_jobs)}</h2>

          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li
              :for={item <- remainder(@packet, @tally_jobs)}
              class="text-base-content text-ui py-3 font-medium"
            >
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
