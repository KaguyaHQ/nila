defmodule NilaWeb.MonthLive do
  use NilaWeb, :live_view

  @moduledoc """
  The client-month workbench: the one room where a month gets closed. The
  junior's unit of work is "close Ravi's June" — this page is that unit made
  visible: a state strip saying who the month waits on, then the month's
  story in filing order — the GSTR-1 (files the 11th), the purchase register
  (2B recon, ITC), and the assembled GSTR-3B (files the 20th).

  Both returns follow the same certification arc on this page: maker works →
  senior signs (figures freeze into the signature's snapshot) → someone
  marks it filed. The strip reads `Nila.Gst.Today.blocking_state/1` — the
  same derivation as the front door's sections, so the row that sent you
  here and the strip you land on can never disagree.
  """

  alias Nila.Accounts.Policy
  alias Nila.Clients

  alias Nila.Gst.{
    ClientMonths,
    Resolutions,
    SalesMonths,
    SalesResolutions,
    SalesWorkings,
    Signoffs,
    Today
  }

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    with true <- org != nil,
         {:ok, client} <- Clients.get_client(org.id, client_id),
         %{} = socket <- try_load(socket, client, period) do
      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That month isn't available.")
         |> push_navigate(to: ~p"/today")}
    end
  end

  defp try_load(socket, client, period) do
    org_id = socket.assigns.current_scope.current_org.id
    purchase = fetch_or_nil(ClientMonths.get_by_period(org_id, client.id, period))
    sales = fetch_or_nil(SalesMonths.get_by_period(org_id, client.id, period))

    if purchase || sales do
      socket
      |> assign(:client, client)
      |> assign(:period, period)
      |> assign(:page_title, "#{client.name} · #{period_label(period)}")
      |> assign(:selected_row, nil)
      |> assign(:selected_inum, nil)
      |> assign(:correcting, nil)
      |> assign_month(purchase, sales)
    else
      nil
    end
  end

  defp fetch_or_nil({:ok, value}), do: value
  defp fetch_or_nil({:error, :not_found}), do: nil

  defp reload(socket) do
    %{client: client, period: period} = socket.assigns
    org_id = socket.assigns.current_scope.current_org.id
    purchase = fetch_or_nil(ClientMonths.get_by_period(org_id, client.id, period))
    sales = fetch_or_nil(SalesMonths.get_by_period(org_id, client.id, period))
    assign_month(socket, purchase, sales)
  end

  defp assign_month(socket, purchase, sales) do
    socket
    |> assign_purchase(purchase)
    |> assign_sales(sales)
    |> assign_strip(purchase, sales)
  end

  # ---------------------------------------------------------------------------
  # Purchase side (register, ITC, 3B) — renders from the 3B signature's frozen
  # snapshot when signed, the live workings otherwise.
  # ---------------------------------------------------------------------------

  defp assign_purchase(socket, nil) do
    socket
    |> assign(:purchase_month, nil)
    |> assign(:gstr3b_signoff, nil)
    |> assign(:rows, [])
    |> assign(:stats, nil)
    |> assign(:gstr3b, nil)
  end

  defp assign_purchase(socket, purchase) do
    signoff = fetch_or_nil(Signoffs.latest_signoff(purchase.id))

    {rows, summary, gstr3b} =
      case signoff do
        nil ->
          workings = Resolutions.workings(purchase)
          {workings.rows, workings.summary, workings.gstr3b}

        signoff ->
          {signoff.snapshot["rows"], signoff.snapshot["summary"], signoff.snapshot["gstr3b"]}
      end

    socket
    |> assign(:purchase_month, purchase)
    |> assign(:gstr3b_signoff, signoff)
    |> assign(:rows, build_rows(rows, purchase))
    |> assign(:stats, build_stats(summary))
    |> assign(:gstr3b, gstr3b)
  end

  defp build_rows(rows, purchase) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      urls =
        row
        |> Map.get("images", [])
        |> Enum.map(fn path ->
          ~p"/gst/#{purchase.client_id}/#{purchase.period}/evidence/#{Path.basename(path)}"
        end)

      row
      |> Map.put("image_urls", urls)
      |> Map.put("dom_id", row_dom_id(row, index))
    end)
  end

  defp row_dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp row_dom_id(_row, index), do: "gst-row-idx-#{index}"

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

  # ---------------------------------------------------------------------------
  # Sales side (GSTR-1) — renders from the R1 signature's frozen snapshot when
  # signed, the effective workings otherwise.
  # ---------------------------------------------------------------------------

  defp assign_sales(socket, nil) do
    socket
    |> assign(:sales_month, nil)
    |> assign(:r1_signoff, nil)
    |> assign(:invoices, [])
    |> assign(:issues_by_invoice, %{})
    |> assign(:month_issues, [])
    |> assign(:flagged, MapSet.new())
    |> assign(:open_issue_count, 0)
    |> assign(:reviewable, false)
  end

  defp assign_sales(socket, sales) do
    signoff = fetch_or_nil(Signoffs.latest_gstr1_signoff(sales.id))

    {effective_invoices, issues, flagged} =
      case signoff do
        nil when sales.invoices == [] ->
          {[], [], MapSet.new()}

        nil ->
          workings = SalesResolutions.workings(sales)
          {workings.invoices, workings.issues, workings.flagged}

        signoff ->
          {signoff.snapshot["invoices"], signoff.snapshot["issues"], MapSet.new()}
      end

    invoices =
      sales.invoices
      |> Enum.zip(effective_invoices)
      |> Enum.map(fn {pristine, effective} ->
        effective
        |> Map.put("pristine_inum", pristine["invoice_number"])
        |> Map.put("image_urls", sales_image_urls(effective, sales))
      end)

    {month_issues, invoice_issues} = Enum.split_with(issues, &is_nil(&1["invoice"]))

    socket
    |> assign(:sales_month, sales)
    |> assign(:r1_signoff, signoff)
    |> assign(:invoices, invoices)
    |> assign(:issues_by_invoice, Enum.group_by(invoice_issues, & &1["invoice"]))
    |> assign(:month_issues, month_issues)
    |> assign(:flagged, flagged)
    |> assign(:open_issue_count, Enum.count(issues, &(&1["status"] == "open")))
    |> assign(:reviewable, SalesWorkings.reviewable?(issues))
  end

  # Dump-based months carry the stored evidence basename on the invoice
  # (namespaced per dump); older months derive it from the page number.
  defp sales_image_urls(invoice, sales) do
    case {invoice["image"], invoice["page"]} do
      {basename, _} when is_binary(basename) ->
        [~p"/gstr1/#{sales.client_id}/#{sales.period}/evidence/#{basename}"]

      {_, page} when is_integer(page) ->
        basename = "page_" <> String.pad_leading(Integer.to_string(page), 2, "0") <> ".png"
        [~p"/gstr1/#{sales.client_id}/#{sales.period}/evidence/#{basename}"]

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # The strip — same derivation as Today's sections.
  # ---------------------------------------------------------------------------

  defp assign_strip(socket, purchase, sales) do
    %{stats: stats, r1_signoff: r1_signoff, gstr3b_signoff: gstr3b_signoff} = socket.assigns

    r1_filed = sales != nil and sales.filed_at != nil
    gstr3b_filed = purchase != nil and purchase.filed_at != nil

    state =
      Today.blocking_state(%{
        purchase: purchase,
        sales: sales,
        need_decision: (stats && stats.need_decision) || 0,
        r1_signed: r1_signoff != nil,
        r1_filed: r1_filed,
        gstr3b_signed: gstr3b_signoff != nil,
        gstr3b_filed: gstr3b_filed
      })

    socket
    |> assign(:blocking_state, state)
    |> assign(
      :deadline,
      Today.deadline(socket.assigns.period, Date.utc_today(), r1_filed, gstr3b_filed)
    )
  end

  defp strip_label(:to_file), do: "Signed — file on the portal"
  defp strip_label(:needs_you), do: "Needs you"
  defp strip_label(:waiting_on_client), do: "Waiting on the client"
  defp strip_label(:waiting_on_senior), do: "Waiting on a senior"
  defp strip_label(:done), do: "Done — both returns filed"

  defp strip_variant(:to_file), do: "error"
  defp strip_variant(:needs_you), do: "warning"
  defp strip_variant(:done), do: "success"
  defp strip_variant(_), do: "neutral"

  # Missing-side wording stays neutral — "not in yet" states a fact; "missing"
  # would tell the firm to chase something that may simply not exist.
  defp strip_detail(assigns) do
    [
      assigns.sales_month == nil && "sales bills not in yet",
      assigns.purchase_month == nil && "purchase bills not in yet",
      assigns.stats && assigns.stats.need_decision > 0 &&
        "#{assigns.stats.need_decision} purchase decisions open",
      assigns.open_issue_count > 0 && "#{assigns.open_issue_count} sales issues open"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # ---------------------------------------------------------------------------
  # Events — sales verbs carry the r1- prefix, purchase/3B verbs the 3b-.
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select-row", %{"dom_id" => dom_id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1["dom_id"] == dom_id))
    {:noreply, assign(socket, selected_row: row, selected_inum: nil)}
  end

  def handle_event("select-invoice", %{"inum" => inum}, socket) do
    {:noreply, assign(socket, selected_inum: inum, selected_row: nil, correcting: nil)}
  end

  def handle_event("close-evidence", _params, socket) do
    {:noreply, assign(socket, selected_row: nil, selected_inum: nil, correcting: nil)}
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

  def handle_event("r1-sign-off", _params, socket) do
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

  def handle_event("r1-reopen-signoff", _params, socket) do
    case Signoffs.reopen(socket.assigns.r1_signoff, socket.assigns.current_scope) do
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

  def handle_event("r1-mark-filed", params, socket) do
    case Signoffs.mark_filed(
           socket.assigns.sales_month,
           socket.assigns.current_scope,
           arn(params)
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "GSTR-1 marked filed.")}

      {:error, :not_signed} ->
        {:noreply, put_flash(socket, :error, "Sign off the GSTR-1 before marking it filed.")}

      {:error, :already_filed} ->
        {:noreply, reload(socket)}
    end
  end

  def handle_event("3b-sign-off", _params, socket) do
    case Signoffs.sign_off(socket.assigns.purchase_month, socket.assigns.current_scope) do
      {:ok, _signoff} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Month signed off.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to sign off this month.")}

      {:error, :already_signed} ->
        {:noreply, put_flash(socket, :error, "This month is already signed off.")}
    end
  end

  def handle_event("3b-reopen-signoff", _params, socket) do
    case Signoffs.reopen(socket.assigns.gstr3b_signoff, socket.assigns.current_scope) do
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

  def handle_event("3b-mark-filed", params, socket) do
    case Signoffs.mark_filed(
           socket.assigns.purchase_month,
           socket.assigns.current_scope,
           arn(params)
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "GSTR-3B marked filed.")}

      {:error, :not_signed} ->
        {:noreply, put_flash(socket, :error, "Sign off the month before marking it filed.")}

      {:error, :already_filed} ->
        {:noreply, reload(socket)}
    end
  end

  defp arn(params) do
    case params["arn"] |> to_string() |> String.trim() do
      "" -> nil
      arn -> arn
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

  # ---------------------------------------------------------------------------
  # Sales helpers
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Purchase helpers
  # ---------------------------------------------------------------------------

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
      <div id="month-page" class="mx-auto max-w-6xl space-y-6">
        <.page_header eyebrow="Client month" title={"#{@client.name} · #{period_label(@period)}"}>
          The whole month in one room — the GSTR-1, the purchase register, and the
          assembled 3B, in the order they file.
        </.page_header>

        <div
          id="month-strip"
          class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
        >
          <.badge variant={strip_variant(@blocking_state)}>
            {strip_label(@blocking_state)}
          </.badge>
          <span :if={strip_detail(assigns)} class="text-base-content/70 text-small">
            {strip_detail(assigns)}
          </span>
          <span class="flex-1"></span>
          <span :if={@deadline} id="month-deadline">
            <.badge variant="neutral">
              {@deadline.return} · {deadline_label(@deadline.days_left)}
            </.badge>
          </span>
          <nav class="text-base-content/60 text-fine flex items-center gap-3">
            <a :if={@sales_month} href="#month-sales" class="hover:text-base-content">Sales</a>
            <a :if={@purchase_month} href="#month-purchases" class="hover:text-base-content">
              Purchases
            </a>
            <a :if={@purchase_month} href="#month-3b" class="hover:text-base-content">3B</a>
          </nav>
        </div>

        <section :if={@sales_month} id="month-sales" class="scroll-mt-4 space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-base-content font-semibold">GSTR-1 — outward</h2>
              <p class="text-base-content/60 text-small">
                {length(@invoices)} invoices ·
                <span class={[
                  @open_issue_count > 0 && "text-warning",
                  @open_issue_count == 0 && "text-base-content/60"
                ]}>
                  {@open_issue_count} open issues
                </span>
              </p>
            </div>
            <div class="flex items-center gap-2">
              <span :if={@sales_month.state == "reviewed"} id="gstr1-reviewed-badge">
                <.badge variant="success">Reviewed</.badge>
              </span>
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
                  @sales_month.state == "reviewed" and is_nil(@r1_signoff) and
                    Policy.can?(@current_scope, :sign_off)
                }
                id="gstr1-signoff-button"
                phx-click="r1-sign-off"
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

          <div
            :if={@r1_signoff}
            id="gstr1-signoff-banner"
            class="bg-success/[0.04] border-success/40 rounded-box flex items-center gap-2 border px-4 py-3"
          >
            <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
            <p class="text-base-content text-small flex-1">
              GSTR-1 signed off by {(@r1_signoff.signed_by && @r1_signoff.signed_by.name) || "—"} · {format_display_datetime(
                @r1_signoff.inserted_at
              )} — figures are frozen as approved.
              <span :if={@sales_month.filed_at} id="gstr1-filed-note" class="font-medium">
                Filed {format_display_datetime(@sales_month.filed_at)}{if @sales_month.filing_arn,
                  do: " · ARN #{@sales_month.filing_arn}"}.
              </span>
            </p>
            <form
              :if={is_nil(@sales_month.filed_at)}
              id="gstr1-mark-filed"
              phx-submit="r1-mark-filed"
              class="flex items-center gap-2"
            >
              <.input
                type="text"
                name="arn"
                id="gstr1-filed-arn"
                value=""
                placeholder="ARN (optional)"
                class="input input-sm w-40 font-mono"
              />
              <.button type="submit" variant="success" size="xs">Filed on portal</.button>
            </form>
            <.button
              :if={Policy.can?(@current_scope, :sign_off) and is_nil(@sales_month.filed_at)}
              id="gstr1-reopen-signoff"
              variant="ghost"
              size="xs"
              phx-click="r1-reopen-signoff"
              data-confirm="Reopen this signed GSTR-1? The signature is revoked — and any GSTR-3B signed against it is reopened too."
            >
              Reopen
            </.button>
          </div>

          <div :if={@month_issues != []} id="gstr1-month-issues" class="space-y-2">
            <div
              :for={issue <- @month_issues}
              id={"gstr1-month-issue-#{issue["code"]}"}
              class="border-base-300 rounded-box flex flex-wrap items-center gap-3 border px-4 py-3"
            >
              <.badge variant={
                if issue["status"] == "resolved",
                  do: "success",
                  else: severity_variant(issue["level"])
              }>
                {issue_label(issue["code"])}
              </.badge>
              <span class="text-base-content/80 text-small min-w-0 flex-1">{issue["message"]}</span>
              <.button
                :if={issue["status"] == "open" and is_nil(@r1_signoff)}
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
                  :if={is_nil(@r1_signoff)}
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
              <span
                :if={open_issues(@issues_by_invoice, invoice) > 0}
                class="text-small text-warning"
              >
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
        </section>

        <div
          :if={!@sales_month}
          id="month-sales-missing"
          class="border-base-300 rounded-box text-base-content/60 text-small border border-dashed px-4 py-6 text-center"
        >
          No sales bills for this period yet — the GSTR-1 derives once they arrive.
        </div>

        <section :if={@purchase_month} id="month-purchases" class="scroll-mt-4 space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="text-base-content font-semibold">Purchases — 2B reconciliation</h2>
              <p class="text-base-content/60 text-small">
                Every row is one tap from its scanned bill — matched lines sit quiet, the
                pile that needs a decision is flagged.
              </p>
            </div>
          </div>

          <div id="gst-stats" class="grid grid-cols-2 gap-4 lg:grid-cols-4">
            <.stat_card label="Invoices" value_id="gst-stat-invoices">
              {@stats.invoices}
            </.stat_card>
            <.stat_card label="Matched to 2B" value_id="gst-stat-matched">
              {@stats.matched}
            </.stat_card>
            <.link navigate={~p"/gst/#{@client.id}/#{@period}/exceptions"} id="gst-open-exceptions">
              <.stat_card label="Need a decision" value_id="gst-stat-need-decision">
                {@stats.need_decision}
              </.stat_card>
            </.link>
            <.stat_card label="ITC / matched tax" value_id="gst-stat-matched-tax" figure>
              {format_money(@stats.matched_tax_paise, prefix: "₹")}
            </.stat_card>
          </div>

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
              <span :if={attention?(row)} class="text-base-content text-small">
                {row_note(row)}
              </span>
              <span :if={!attention?(row)} class="text-base-content/35 text-fine">
                matched
              </span>
            </:col>
          </.data_table>
        </section>

        <div
          :if={!@purchase_month}
          id="month-purchases-missing"
          class="border-base-300 rounded-box text-base-content/60 text-small border border-dashed px-4 py-6 text-center"
        >
          No purchase bills for this period yet — the 2B reconciliation and the 3B need them.
        </div>

        <section :if={@purchase_month} id="month-3b" class="scroll-mt-4 space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-base-content font-semibold">GSTR-3B — the month's ending</h2>
            <.button
              :if={@purchase_month.state == "worked" and Policy.can?(@current_scope, :sign_off)}
              id="gst-signoff-button"
              variant="primary"
              size="sm"
              phx-click="3b-sign-off"
            >
              <.icon name="hero-check-badge-mini" class="size-4" /> Sign off month
            </.button>
          </div>

          <div
            :if={@gstr3b_signoff}
            id="gst-signoff-banner"
            class="bg-success/[0.04] border-success/40 rounded-box flex items-center gap-2 border px-4 py-3"
          >
            <.icon name="hero-check-badge" class="text-success size-5 shrink-0" />
            <p class="text-base-content text-small flex-1">
              Signed off by {(@gstr3b_signoff.signed_by && @gstr3b_signoff.signed_by.name) || "—"} · {format_display_datetime(
                @gstr3b_signoff.inserted_at
              )} — figures are frozen as approved.
              <span :if={@purchase_month.filed_at} id="gst-filed-note" class="font-medium">
                Filed {format_display_datetime(@purchase_month.filed_at)}{if @purchase_month.filing_arn,
                  do: " · ARN #{@purchase_month.filing_arn}"}.
              </span>
            </p>
            <form
              :if={is_nil(@purchase_month.filed_at)}
              id="gst-mark-filed"
              phx-submit="3b-mark-filed"
              class="flex items-center gap-2"
            >
              <.input
                type="text"
                name="arn"
                id="gst-filed-arn"
                value=""
                placeholder="ARN (optional)"
                class="input input-sm w-40 font-mono"
              />
              <.button type="submit" variant="success" size="xs">Filed on portal</.button>
            </form>
            <.button
              :if={Policy.can?(@current_scope, :sign_off) and is_nil(@purchase_month.filed_at)}
              id="gst-reopen-signoff"
              variant="ghost"
              size="xs"
              phx-click="3b-reopen-signoff"
              data-confirm="Reopen this signed month? The signature is revoked and the month can be worked again."
            >
              Reopen
            </.button>
          </div>

          {gstr3b_panel(assigns)}
        </section>
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
                  {issue_label(flag["code"])}
                </.badge>
                <p class="text-base-content/80 text-small mt-2">{flag["reason"]}</p>
              </div>
            </div>
          </div>
        </div>
      </.modal>

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
                    :if={issue["status"] == "open" and is_nil(@r1_signoff)}
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
                      :if={is_nil(@r1_signoff)}
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

  defp deadline_label(days) when days < 0, do: "#{-days}d overdue"
  defp deadline_label(0), do: "due today"
  defp deadline_label(days), do: "#{days}d left"

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
end
