defmodule NilaWeb.Gstr1MonthLive do
  use NilaWeb, :live_view

  alias Nila.Accounts.Policy
  alias Nila.Gst.{SalesMonths, SalesResolutions, SalesWorkings, Signoffs}
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
         |> assign(:selected_inum, nil)
         |> assign(:correcting, nil)
         |> load_workings(sales_month)}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That sales month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end

  # Everything renders from the effective workings — the engine's output with
  # every human resolution replayed over it — so the table, the issues, and
  # the JSON download can never disagree with the stored decisions. A signed
  # month is the exception: it renders from the signature's frozen snapshot,
  # never a live re-derivation, so the numbers under the signature cannot
  # drift when the engine improves.
  defp load_workings(socket, sales_month) do
    signoff =
      case Signoffs.latest_gstr1_signoff(sales_month.id) do
        {:ok, signoff} -> signoff
        {:error, :not_found} -> nil
      end

    {effective_invoices, issues, flagged} =
      case signoff do
        nil ->
          workings = SalesResolutions.workings(sales_month)
          {workings.invoices, workings.issues, workings.flagged}

        signoff ->
          {signoff.snapshot["invoices"], signoff.snapshot["issues"], MapSet.new()}
      end

    invoices =
      sales_month.invoices
      |> Enum.zip(effective_invoices)
      |> Enum.map(fn {pristine, effective} ->
        effective
        |> Map.put("pristine_inum", pristine["invoice_number"])
        |> Map.put("image_urls", image_urls(effective, sales_month))
      end)

    {month_issues, invoice_issues} = Enum.split_with(issues, &is_nil(&1["invoice"]))

    socket
    |> assign(:sales_month, sales_month)
    |> assign(:signoff, signoff)
    |> assign(:invoices, invoices)
    |> assign(:issues_by_invoice, Enum.group_by(invoice_issues, & &1["invoice"]))
    |> assign(:month_issues, month_issues)
    |> assign(:flagged, flagged)
    |> assign(:open_issue_count, Enum.count(issues, &(&1["status"] == "open")))
    |> assign(:reviewable, SalesWorkings.reviewable?(issues))
  end

  defp reload(socket) do
    sales_month = socket.assigns.sales_month |> Repo.reload!() |> Repo.preload(:client)
    load_workings(socket, sales_month)
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
    {:noreply, assign(socket, selected_inum: inum, correcting: nil)}
  end

  def handle_event("close-evidence", _params, socket) do
    {:noreply, assign(socket, selected_inum: nil, correcting: nil)}
  end

  def handle_event("confirm_issue", %{"target" => target}, socket) do
    record(socket, %{"verb" => "confirm_issue", "target" => target})
  end

  def handle_event("undo", %{"target" => target}, socket) do
    record(socket, %{"verb" => "reopen", "target" => target})
  end

  def handle_event("start_correct", %{"field" => field}, socket) do
    invoice = selected_invoice(socket.assigns)

    {:noreply,
     assign(socket, :correcting, %{field: field, value: to_string(field_value(invoice, field))})}
  end

  def handle_event("cancel_correct", _params, socket) do
    {:noreply, assign(socket, :correcting, nil)}
  end

  def handle_event("save_correct", %{"field" => field, "value" => value}, socket) do
    invoice = selected_invoice(socket.assigns)
    from = field_value(invoice, field)
    value = String.trim(value)

    if value == "" or value == to_string(from) do
      {:noreply, assign(socket, :correcting, nil)}
    else
      record(socket, %{
        "verb" => "correct_field",
        "target" => invoice["pristine_inum"],
        "payload" => %{"field" => field, "from" => from, "to" => coerce(field, value)}
      })
    end
  end

  def handle_event("mark_reviewed", _params, socket) do
    case SalesResolutions.mark_reviewed(socket.assigns.sales_month) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Sales month marked reviewed.")}

      {:error, :open_issues} ->
        {:noreply, put_flash(socket, :error, "Open issues remain — resolve them first.")}
    end
  end

  def handle_event("sign_off", _params, socket) do
    case Signoffs.sign_off_gstr1(socket.assigns.sales_month, socket.assigns.current_scope) do
      {:ok, _signoff} ->
        {:noreply, socket |> reload() |> put_flash(:info, "GSTR-1 signed off.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to sign off.")}

      {:error, :not_reviewed} ->
        {:noreply, put_flash(socket, :error, "Mark the month reviewed first.")}

      {:error, :already_signed} ->
        {:noreply, put_flash(socket, :error, "This GSTR-1 is already signed off.")}
    end
  end

  def handle_event("reopen_signoff", _params, socket) do
    case Signoffs.reopen(socket.assigns.signoff, socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Signature reopened — the month can be worked again.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to reopen.")}

      {:error, :already_revoked} ->
        {:noreply, reload(socket)}
    end
  end

  defp record(socket, attrs) do
    case SalesResolutions.record(
           socket.assigns.sales_month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> assign(:correcting, nil)}

      {:error, :signed_off} ->
        {:noreply,
         put_flash(socket, :error, "This GSTR-1 is signed off — a senior must reopen it first.")}
    end
  end

  defp selected_invoice(%{selected_inum: nil}), do: nil

  defp selected_invoice(assigns) do
    Enum.find(assigns.invoices, &(&1["invoice_number"] == assigns.selected_inum)) ||
      Enum.find(assigns.invoices, &(&1["pristine_inum"] == assigns.selected_inum))
  end

  # The fields a human may correct on this invoice: flagged by the engine
  # (low confidence or implicated in a validation issue) and addressable by
  # `Gstr1.apply_corrections/3` — scalar paths only, not whole-list markers
  # like "line_items" or derived markers like "doc_issue".
  defp correctable_fields(flagged, invoice) do
    flagged
    |> Enum.filter(fn {inum, field} ->
      inum == invoice["pristine_inum"] and correctable?(field)
    end)
    |> Enum.map(fn {_inum, field} -> field end)
    |> Enum.sort()
  end

  defp correctable?(field),
    do: field not in ["line_items", "doc_issue"] and not String.contains?(field, "confidence")

  defp field_value(invoice, field) do
    case Regex.run(~r/^line_items\[(\d+)\]\.(.+)$/, field) do
      [_, index, line_field] ->
        line = Enum.at(invoice["line_items"], String.to_integer(index)) || %{}
        line[line_field]

      _ ->
        invoice[field]
    end
  end

  # Corrected values arrive as text; numeric fields must go back to numbers so
  # the engine's arithmetic and the table's sums keep working on the effective
  # invoices. Only known-numeric fields parse — a purely numeric invoice
  # number must stay a string, or every downstream comparison breaks.
  @numeric_field ~r/^(printed_total_taxable|printed_total_tax|printed_grand_total)$|\.(taxable_value|quantity|unit_price|[csi]gst_(rate|amount))$/

  defp coerce(field, value) do
    with true <- Regex.match?(@numeric_field, field),
         {number, ""} <- Float.parse(value) do
      number
    else
      _ -> value
    end
  end

  defp invoice_issues(issues_by_invoice, invoice) do
    issues_by_invoice[invoice["invoice_number"]] || []
  end

  defp open_issues(issues_by_invoice, invoice) do
    issues_by_invoice |> invoice_issues(invoice) |> Enum.count(&(&1["status"] == "open"))
  end

  defp invoice_taxable(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.map(&(num(&1["taxable_value"]) || 0))
    |> Enum.sum()
  end

  defp invoice_tax(invoice) do
    invoice["line_items"]
    |> List.wrap()
    |> Enum.map(fn line ->
      (num(line["cgst_amount"]) || 0) + (num(line["sgst_amount"]) || 0) +
        (num(line["igst_amount"]) || 0)
    end)
    |> Enum.sum()
  end

  defp num(value) when is_number(value), do: value
  defp num(_), do: 0

  defp severity_variant("error"), do: "error"
  defp severity_variant(_), do: "warning"

  defp rupees(amount) when is_number(amount) do
    Nila.Formatters.format_money_with_paise(round(amount * 100))
  end

  defp rupees(_), do: "—"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :selected_invoice, selected_invoice(assigns))

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
          <.link
            navigate={~p"/gst/#{@sales_month.client_id}/#{@sales_month.period}"}
            id="gstr1-open-purchases"
            class="text-moon font-semibold"
          >
            Open the purchase month →
          </.link>
        </.page_header>

        <div
          :if={@signoff}
          id="gstr1-signoff-banner"
          class="bg-success/[0.04] border-success/40 rounded-box flex items-center gap-2 border px-4 py-3"
        >
          <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
          <p class="text-base-content text-small flex-1">
            GSTR-1 signed off by {(@signoff.signed_by && @signoff.signed_by.name) || "—"} · {format_display_datetime(
              @signoff.inserted_at
            )} — figures are frozen as approved.
          </p>
          <.button
            :if={Policy.can?(@current_scope, :sign_off)}
            id="gstr1-reopen-signoff"
            variant="ghost"
            size="xs"
            phx-click="reopen_signoff"
            data-confirm="Reopen this signed GSTR-1? The signature is revoked — and any GSTR-3B signed against it is reopened too."
          >
            Reopen
          </.button>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="text-base-content/60 text-small flex items-center gap-2">
            <span :if={@sales_month.state == "reviewed"} id="gstr1-reviewed-badge">
              <.badge variant="success">Reviewed</.badge>
            </span>
            {length(@invoices)} invoices ·
            <span class={[
              @open_issue_count > 0 && "text-warning",
              @open_issue_count == 0 && "text-base-content/60"
            ]}>
              {@open_issue_count} open issues
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.button
              :if={@sales_month.state == "worked" and @reviewable}
              id="gstr1-mark-reviewed"
              phx-click="mark_reviewed"
              variant="success"
              size="sm"
            >
              <.icon name="hero-check-circle" class="size-4" /> Mark reviewed
            </.button>
            <.button
              :if={
                @sales_month.state == "reviewed" and is_nil(@signoff) and
                  Policy.can?(@current_scope, :sign_off)
              }
              id="gstr1-signoff-button"
              phx-click="sign_off"
              variant="primary"
              size="sm"
            >
              <.icon name="hero-check-badge-mini" class="size-4" /> Sign off GSTR-1
            </.button>
            <.button
              id="gstr1-download-json"
              href={~p"/gstr1/#{@sales_month.client_id}/#{@sales_month.period}/return.json"}
              variant="primary"
              size="sm"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Portal JSON
            </.button>
          </div>
        </div>

        <div :if={@month_issues != []} id="gstr1-month-issues" class="space-y-2">
          <div
            :for={issue <- @month_issues}
            id={"gstr1-month-issue-#{issue["code"]}"}
            class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
          >
            <.badge variant={
              if issue["status"] == "resolved", do: "success", else: severity_variant(issue["level"])
            }>
              {issue_label(issue["code"])}
            </.badge>
            <span class="text-base-content/80 text-small min-w-0 flex-1">{issue["message"]}</span>
            <.button
              :if={issue["status"] == "open"}
              variant="outline"
              size="xs"
              phx-click="confirm_issue"
              phx-value-target={SalesWorkings.issue_key(issue)}
            >
              Checked — it's fine
            </.button>
            <span :if={issue["status"] == "resolved"} class="flex items-center gap-1.5">
              <span class="text-fine text-success font-medium">Confirmed</span>
              <.button
                variant="ghost"
                size="xs"
                phx-click="undo"
                phx-value-target={SalesWorkings.issue_key(issue)}
              >
                Undo
              </.button>
            </span>
          </div>
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
                :if={open_issues(@issues_by_invoice, invoice) > 0}
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
            <span :if={open_issues(@issues_by_invoice, invoice) > 0} class="text-small text-warning">
              {open_issues(@issues_by_invoice, invoice)} open
            </span>
            <span
              :if={
                open_issues(@issues_by_invoice, invoice) == 0 and
                  invoice_issues(@issues_by_invoice, invoice) != []
              }
              class="text-small text-success"
            >
              resolved
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

            <div :if={invoice_issues(@issues_by_invoice, @selected_invoice) != []} class="space-y-2">
              <div class="text-base-content/60 text-label font-medium uppercase">Issues</div>
              <div
                :for={issue <- invoice_issues(@issues_by_invoice, @selected_invoice)}
                class="bg-base-200/40 border-base-300 rounded-box border p-3"
              >
                <.badge variant={
                  if issue["status"] == "resolved",
                    do: "success",
                    else: severity_variant(issue["level"])
                }>
                  {issue_label(issue["code"])}
                </.badge>
                <p class="text-base-content/80 text-small mt-2">{issue["message"]}</p>
                <div class="mt-2">
                  <.button
                    :if={issue["status"] == "open"}
                    variant="outline"
                    size="xs"
                    phx-click="confirm_issue"
                    phx-value-target={SalesWorkings.issue_key(issue)}
                  >
                    Checked against the bill — it's fine
                  </.button>
                  <span :if={issue["status"] == "resolved"} class="flex items-center gap-1.5">
                    <span class="text-fine text-success font-medium">Confirmed</span>
                    <.button
                      variant="ghost"
                      size="xs"
                      phx-click="undo"
                      phx-value-target={SalesWorkings.issue_key(issue)}
                    >
                      Undo
                    </.button>
                  </span>
                </div>
              </div>
            </div>

            <div
              :if={correctable_fields(@flagged, @selected_invoice) != []}
              id="gstr1-corrections"
              class="space-y-2"
            >
              <div class="text-base-content/60 text-label font-medium uppercase">
                Flagged fields
              </div>
              <%= for field <- correctable_fields(@flagged, @selected_invoice) do %>
                <%= if @correcting && @correcting.field == field do %>
                  <form phx-submit="save_correct" class="flex items-end gap-2">
                    <.input type="hidden" name="field" id="gstr1-correct-field" value={field} />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name="value"
                        value={@correcting.value}
                        label={field}
                        id="gstr1-correct-value"
                      />
                    </div>
                    <.button type="submit" variant="primary" size="sm">Save</.button>
                    <.button type="button" variant="ghost" size="sm" phx-click="cancel_correct">
                      Cancel
                    </.button>
                  </form>
                <% else %>
                  <div class="flex items-center justify-between gap-2">
                    <span class="text-base-content/70 text-small min-w-0 truncate font-mono">
                      {field} = {to_string(field_value(@selected_invoice, field))}
                    </span>
                    <.button
                      variant="ghost"
                      size="xs"
                      phx-click="start_correct"
                      phx-value-field={field}
                    >
                      Correct
                    </.button>
                  </div>
                <% end %>
              <% end %>
              <p class="text-base-content/50 text-fine">
                Only fields Nila flagged are correctable — fixing anything else would be a
                silent error.
              </p>
            </div>
          </div>
        </div>
      </.modal>
    </Layouts.app>
    """
  end
end
