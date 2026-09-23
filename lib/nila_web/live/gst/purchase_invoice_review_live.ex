defmodule NilaWeb.Gst.PurchaseInvoiceReviewLive do
  use NilaWeb, :live_view

  alias NilaWeb.Components.Gst.PeriodHeader
  alias Nila.Accounts.Policy
  alias Nila.Gst.Purchase.{ItcDecisions, Resolutions, Review}
  alias NilaWeb.Gst.PurchaseWorkspace

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         item: nil,
         correction_form: nil,
         correction_books_id: nil,
         correction_error: nil,
         itc_form: nil,
         itc_choice: nil,
         itc_error: nil
       )}

  @impl true
  def handle_params(
        %{"client_id" => client_id, "period" => period, "item_id" => id} = params,
        _uri,
        socket
      ) do
    filter = PurchaseWorkspace.normalize_filter(params["filter"])
    q = params["q"] || ""

    case PurchaseWorkspace.load(socket.assigns.current_scope, client_id, period) do
      {:ok, workspace} ->
        case Review.lookup(workspace.items, id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That purchase could not be found.")
             |> push_navigate(to: PurchaseWorkspace.list_path(client_id, period, filter, q))}

          item ->
            {:noreply,
             socket
             |> assign(workspace)
             |> assign(
               client_id: client_id,
               period: period,
               filing_picker_year: String.to_integer(String.slice(period, 0, 4)),
               filter: filter,
               q: q,
               page_title: "Purchase review"
             )
             |> select_item(item)}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "That purchase could not be found.")
         |> push_navigate(to: ~p"/clients")}
    end
  end

  defp select_item(socket, item) do
    queue =
      PurchaseWorkspace.filter(socket.assigns.items, socket.assigns.filter, socket.assigns.q)

    index = Enum.find_index(queue, &(&1.id == item.id))
    previous = if index && index > 0, do: Enum.at(queue, index - 1)
    next = if index, do: Enum.at(queue, index + 1)

    assign(socket,
      item: item,
      cess_issue:
        item
        |> Map.get(:treatment_lines, [])
        |> Enum.find_value(&Nila.Gst.Cess.purchase_issue(&1.invoice_date, &1.outstanding_heads)),
      cess_visible?: cess_visible?(item),
      queue: queue,
      has_books?: PurchaseWorkspace.source_rows(socket.assigns.workings, "register") != [],
      pairing_pending?: pairing_pending?(item, socket.assigns.items),
      treatment: nil,
      treatment_error: nil,
      correction_form: nil,
      correction_books_id: nil,
      correction_error: nil,
      itc_form: nil,
      itc_choice: nil,
      itc_error: nil,
      previous: previous,
      next: next,
      can_edit?:
        Policy.can?(socket.assigns.current_scope, :edit_records) and
          not socket.assigns.signed_off?,
      comparisons: comparisons(item, socket.assigns.workings.rows)
    )
  end

  @impl true
  def handle_event("shift-filing-year", %{"direction" => direction}, socket)
      when direction in ["previous", "next"] do
    offset = if direction == "previous", do: -1, else: 1
    year = (socket.assigns.filing_picker_year + offset) |> max(1) |> min(Date.utc_today().year)
    {:noreply, assign(socket, :filing_picker_year, year)}
  end

  def handle_event("start-correction", %{"books" => books_id}, socket) do
    row = Enum.find(socket.assigns.item.books_members, &(&1["id"] == books_id))

    if row && socket.assigns.can_edit? do
      values = Map.new(~w(taxable_paise total_paise), &{&1, decimal_amount(row[&1] || 0)})

      values =
        Enum.reduce(
          ~w(cgst sgst igst cess),
          values,
          &Map.put(&2, &1, decimal_amount(get_in(row, ["tax_paise", &1]) || 0))
        )

      {:noreply,
       assign(socket,
         correction_books_id: books_id,
         correction_form: to_form(Map.put(values, "reason", ""), as: :correction),
         correction_error: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-correction", _params, socket),
    do:
      {:noreply,
       assign(socket, correction_form: nil, correction_books_id: nil, correction_error: nil)}

  def handle_event("save-correction", %{"correction" => params}, socket) do
    %{current_scope: scope, client_id: client_id, period: period, item: selected} = socket.assigns

    with true <- Policy.can?(scope, :edit_records),
         {:ok, workspace} <- PurchaseWorkspace.load(scope, client_id, period),
         false <- workspace.signed_off?,
         item when not is_nil(item) <- Review.lookup(workspace.items, selected.id),
         row when not is_nil(row) <-
           Enum.find(item.books_members, &(&1["id"] == socket.assigns.correction_books_id)),
         {:ok, values, reason} <- correction_values(params, row),
         attrs when attrs != [] <- correction_attrs(row, values, reason),
         {:ok, _result} <- record(workspace.month, attrs, scope.user.id) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Purchase values corrected. Matching and workings have been recalculated."
       )
       |> push_navigate(to: list_path(socket.assigns))}
    else
      {:error, message} when is_binary(message) ->
        {:noreply,
         assign(socket,
           correction_form: to_form(params, as: :correction),
           correction_error: message
         )}

      {:error, reason}
      when reason in [:treated_source_cannot_be_removed, :treatment_prevents_source_move] ->
        {:noreply,
         assign(socket,
           correction_form: to_form(params, as: :correction),
           correction_error:
             "This invoice has an ITC treatment. Change its treatment before changing the source."
         )}

      [] ->
        {:noreply, assign(socket, correction_error: "Change at least one amount before saving.")}

      _ ->
        {:noreply,
         assign(socket,
           correction_error:
             "These values could not be saved. Reopen the invoice and check your access and the month's sign-off."
         )}
    end
  end

  def handle_event("choose-treatment", %{"action" => action}, socket) do
    if socket.assigns.can_edit? and not socket.assigns.pairing_pending? and
         permitted_action?(socket.assigns.item, action) and action != "reopen" do
      {:noreply, assign(socket, treatment: action, treatment_error: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open-itc-treatment", _, socket) do
    item = socket.assigns.item

    if socket.assigns.can_edit? and not socket.assigns.pairing_pending? and
         length(Map.get(item, :treatment_case_ids, [])) == 1 do
      line = hd(item.treatment_lines)
      {choice, values} = review_initial_treatment(line)

      {:noreply,
       assign(socket, itc_form: to_form(values, as: :itc), itc_choice: choice, itc_error: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-itc-treatment", _, socket),
    do: {:noreply, assign(socket, itc_form: nil)}

  def handle_event("choose-itc-treatment", %{"choice" => choice}, socket)
      when choice in ~w(claim later exclude split),
      do: {:noreply, assign(socket, itc_choice: choice, itc_error: nil)}

  def handle_event("apply-itc-treatment", %{"itc" => params}, socket) do
    a = socket.assigns
    attrs = Map.put(params, "choice", a.itc_choice)

    result =
      with true <-
             a.can_edit? and not a.pairing_pending? and
               length(Map.get(a.item, :treatment_case_ids, [])) == 1,
           {:ok, attrs} <- itc_attrs(attrs) do
        ItcDecisions.apply(
          a.current_scope,
          a.client_id,
          a.period,
          a.item.treatment_case_ids,
          attrs
        )
      else
        {:error, _} = error -> error
        _ -> {:error, :unavailable}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "ITC treatment saved.")
         |> push_navigate(to: next_review_path(a, a.item))}

      {:error, reason} ->
        message =
          if reason == :reason_required and review_other_without_note?(params),
            do: "Enter a note for Other.",
            else: itc_error(reason)

        {:noreply, assign(socket, itc_form: to_form(params, as: :itc), itc_error: message)}
    end
  end

  def handle_event("save-treatment", _params, %{assigns: %{treatment: nil}} = socket),
    do: {:noreply, assign(socket, treatment_error: "Choose a treatment before saving.")}

  def handle_event("save-treatment", _params, socket),
    do: handle_event("decide", %{"action" => socket.assigns.treatment, "advance" => true}, socket)

  def handle_event("decide", params, socket) do
    %{current_scope: scope, client_id: client_id, period: period, item: selected} = socket.assigns

    with true <- Policy.can?(scope, :edit_records),
         {:ok, workspace} <- PurchaseWorkspace.load(scope, client_id, period),
         false <- workspace.signed_off?,
         item when not is_nil(item) <- Review.lookup(workspace.items, selected.id),
         false <- pairing_pending?(item, workspace.items),
         true <- permitted_action?(item, params["action"]),
         {:ok, result} <- decide(workspace.month, item, params, scope.user.id) do
      destination =
        if params["advance"] do
          next_review_path(socket.assigns, selected)
        else
          list_path(socket.assigns)
        end

      workspace = %{workspace | month: result.month, workings: result.workings}

      {:noreply,
       socket
       |> assign(workspace)
       |> put_flash(:info, "Decision saved.")
       |> push_navigate(to: destination)}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This decision could not be saved. The month may be signed off or your access may have changed."
         )}
    end
  end

  defp itc_attrs(%{"choice" => "split"} = attrs) do
    heads =
      for part <- ~w(claim later exclude), into: %{} do
        values =
          for head <- ~w(cgst sgst igst cess), into: %{} do
            {head, parse_amount(get_in(attrs, ["split", part, head]) || "0")}
          end

        {part, values}
      end

    if Enum.any?(heads, fn {_part, values} ->
         Enum.any?(values, fn {_head, value} -> value == :error end)
       end),
       do: {:error, :invalid_amount},
       else: {:ok, attrs |> Map.delete("split") |> Map.merge(heads)}
  end

  defp itc_attrs(%{"choice" => choice} = attrs) when choice in ~w(claim later exclude),
    do: {:ok, Map.delete(attrs, "split")}

  defp itc_attrs(_), do: {:error, :choice_required}

  defp next_review_path(a, selected) do
    {:ok, refreshed} = PurchaseWorkspace.load(a.current_scope, a.client_id, a.period)
    remaining = PurchaseWorkspace.filter(refreshed.items, a.filter, a.q)
    index = Enum.find_index(a.queue, &(&1.id == selected.id)) || -1
    order = Enum.drop(a.queue, index + 1) ++ Enum.take(a.queue, index)

    next =
      Enum.find_value(order, fn old ->
        candidate = Review.lookup(remaining, old.id)

        if candidate && candidate.id != selected.id && PurchaseWorkspace.needs_review?(candidate),
          do: candidate
      end)

    if next, do: item_path(a, next), else: list_path(a)
  end

  defp itc_error(:invalid_amount), do: "Enter rupee amounts with no more than two decimal places."
  defp itc_error(:choice_required), do: "Choose an ITC treatment."
  defp itc_error(:reason_required), do: "Choose a reason for this treatment."
  defp itc_error(:note_required), do: "Enter a note for Other."

  defp itc_error(:amounts_do_not_balance),
    do: "Split amounts must add up to each available tax head."

  defp itc_error(:invalid_amounts),
    do: "Enter rupee amounts with no more than two decimal places."

  defp itc_error(:cess_review_required),
    do: "CESS needs separate review and cannot be claimed or carried forward in Nila."

  defp itc_error(:claim_not_available),
    do: "Claim is blocked for this invoice. Review its checks first."

  defp itc_error(:itc_blocked), do: "Claim is blocked for this invoice. Review its checks first."

  defp itc_error(:later_treatment_exists),
    do: "A later month already has a treatment for this invoice. Change that month first."

  defp itc_error(:later_signed_treatment),
    do: "A later signed working depends on this invoice. Reopen that month first."

  defp itc_error(:already_allocated),
    do: "This credit is already included in a signed working. Reopen that working first."

  defp itc_error(reason) when is_binary(reason), do: reason
  defp itc_error(_), do: "Could not save this treatment. Review the invoice and try again."

  defp review_other_without_note?(params) do
    (params["later_reason"] == "other" or params["exclude_reason"] == "other") and
      String.trim(params["note"] || "") == ""
  end

  defp correction_values(params, row), do: Nila.Gst.Purchase.SourceCorrections.values(params, row)

  defp correction_attrs(row, values, reason),
    do: Nila.Gst.Purchase.SourceCorrections.attrs(row, values, reason)

  defp parse_amount(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A\d{1,13}(?:\.\d{1,2})?\z/, value) do
      [whole | decimals] = String.split(value, ".")

      String.to_integer(whole) * 100 +
        String.to_integer(String.pad_trailing(List.first(decimals) || "0", 2, "0"))
    else
      :error
    end
  end

  defp parse_amount(_), do: :error

  defp decimal_amount(paise),
    do: "#{div(paise, 100)}.#{String.pad_leading(to_string(rem(paise, 100)), 2, "0")}"

  defp decide(month, %{kind: :books, resolved: false} = item, %{"action" => action}, user_id)
       when action in ~w(await_2b not_claimable) do
    record(
      month,
      Enum.map(
        item.member_ids,
        &%{"verb" => "accept_unmatched", "books_id" => &1, "payload" => %{"reason" => action}}
      ),
      user_id
    )
  end

  defp decide(month, %{kind: :gstr2b} = item, %{"action" => action}, user_id)
       when action in ~w(dismiss_2b held not_held) do
    event =
      %{
        "dismiss_2b" => "excluded_not_ours",
        "held" => "client_holds_document",
        "not_held" => "document_not_held"
      }[action]

    attrs =
      if action == "dismiss_2b",
        do: [%{"verb" => "dismiss_2b", "gstr2b_ref" => item.gstr2b_ref}],
        else: []

    Resolutions.record_itc_case_event_and_refresh(month, item.itc_case_id, event, attrs, user_id)
  end

  defp decide(month, %{kind: :itc, itc_block: block}, %{"action" => action}, user_id)
       when action in ~w(block_itc allow_itc) do
    record(month, [%{"verb" => action, "payload" => %{"block_id" => block["block_id"]}}], user_id)
  end

  defp decide(month, %{kind: :books} = item, %{"action" => "reopen"}, user_id) do
    record(month, Enum.map(item.member_ids, &%{"verb" => "reopen", "books_id" => &1}), user_id)
  end

  defp decide(month, %{kind: :gstr2b} = item, %{"action" => "reopen"}, user_id) do
    attrs =
      if item.verb == "dismiss_2b",
        do: [%{"verb" => "reopen", "gstr2b_ref" => item.gstr2b_ref}],
        else: []

    Resolutions.record_itc_case_event_and_refresh(
      month,
      item.itc_case_id,
      "reopened",
      attrs,
      user_id
    )
  end

  defp decide(month, %{kind: :itc, itc_block: block}, %{"action" => "reopen"}, user_id) do
    record(
      month,
      [%{"verb" => "reopen", "payload" => %{"block_id" => block["block_id"]}}],
      user_id
    )
  end

  defp decide(_month, _item, _params, _user_id), do: {:error, :invalid_action}

  defp record(month, attrs, user_id),
    do: Resolutions.record_many_and_refresh(month, attrs, user_id)

  defp comparisons(%{candidates: [_ | _] = candidates}, _rows), do: candidates

  defp comparisons(%{kind: :itc} = item, rows) do
    row =
      Enum.find(
        rows,
        &(&1["invoice_number"] == item.invoice_number and &1["vendor_name"] == item.vendor and
            (&1["document_type"] || "invoice") == item.document_type)
      )

    books =
      if row,
        do:
          Map.put(
            row,
            "tax_paise",
            Map.new(~w(cgst sgst igst cess), &{&1, row[&1 <> "_paise"] || 0})
          )

    [%{books: books, gstr2b: nil, books_id: nil, ref: nil}]
  end

  defp comparisons(item, _rows),
    do: [
      %{
        books: item.books,
        gstr2b: item.gstr2b || List.first(item.counterparts),
        books_id: nil,
        ref: nil
      }
    ]

  defp facts(pair) do
    for {label, key} <- [
          {"Supplier", "vendor_name"},
          {"GSTIN", "vendor_gstin"},
          {"Invoice number", "invoice_number"},
          {"Invoice date", "invoice_date"},
          {"Taxable value", "taxable_paise"},
          {"CGST", "cgst"},
          {"SGST", "sgst"},
          {"IGST", "igst"},
          {"CESS", "cess"},
          {"Total", "total_paise"}
        ],
        key != "cess" or source_cess?(pair.books) or source_cess?(pair.gstr2b) do
      books = fact(pair.books, key)
      portal = fact(pair.gstr2b, key)

      %{
        label: label,
        books: books,
        portal: portal,
        different?: pair.books != nil and pair.gstr2b != nil and books != portal
      }
    end
  end

  defp fact(nil, _key), do: "—"

  defp fact(row, key) when key in ~w(cgst sgst igst cess),
    do: PurchaseWorkspace.money(get_in(row, ["tax_paise", key]) || 0)

  defp fact(row, key) when key in ~w(taxable_paise total_paise),
    do: if(is_nil(row[key]), do: "—", else: PurchaseWorkspace.money(row[key]))

  defp fact(row, key), do: to_string(row[key] || "—")

  defp original_path(assigns, row) do
    case Regex.run(~r/^d(\d+)_excel_\d+$/, (row && row["id"]) || "") do
      [_, dump_id] -> "/gst/#{assigns.client_id}/#{assigns.period}/original/#{dump_id}/0"
      _ -> nil
    end
  end

  defp list_path(a), do: PurchaseWorkspace.list_path(a.client_id, a.period, a.filter, a.q)

  defp item_path(a, item),
    do: PurchaseWorkspace.review_path(a.client_id, a.period, item.id, a.filter, a.q)

  defp pairing_pending?(item),
    do: item.kind == :books and not item.resolved and item.candidates != []

  defp pairing_pending?(%{kind: :itc} = item, items) do
    Enum.any?(items, fn other ->
      pairing_pending?(other) and
        Enum.any?(other.books_members, fn books ->
          Nila.Gst.Filing.ItcPosition.block_id(books["id"], item.itc_block["code"]) ==
            item.itc_block["block_id"] or
            (item.itc_block["code"] == "duplicate_invoice" and
               books["vendor_name"] == item.vendor and
               Nila.Gst.InvoiceNumber.key(books["invoice_number"]) ==
                 Nila.Gst.InvoiceNumber.key(item.invoice_number) and
               (books["document_type"] || "invoice") == item.document_type)
        end)
    end)
  end

  defp pairing_pending?(item, _items), do: pairing_pending?(item)

  defp treatments(%{kind: :gstr2b, document_state: state, verb: verb})
       when state not in ~w(present held not_held) and verb != "dismiss_2b",
       do: [
         {"held", "Client holds document"},
         {"not_held", "Document not received"},
         {"dismiss_2b", "Not ours"}
       ]

  defp treatments(%{resolved: true}), do: []

  defp treatments(%{kind: :books, candidates: []}),
    do: [{"await_2b", "Keep pending for 2B"}, {"not_claimable", "No ITC this month"}]

  defp treatments(%{kind: :gstr2b}),
    do: [
      {"held", "Client holds document"},
      {"not_held", "Document not received"},
      {"dismiss_2b", "Not ours"}
    ]

  defp treatments(%{kind: :itc}),
    do: [{"block_itc", "Block credit"}, {"allow_itc", "Keep credit"}]

  defp treatments(_), do: []

  defp permitted_action?(item, "reopen"), do: item.resolved and not is_nil(item.outcome)
  defp permitted_action?(item, action), do: action in Enum.map(treatments(item), &elem(&1, 0))

  defp treatment_reason("await_2b"),
    do: "The purchase is missing from GSTR-2B. Keep it pending for the supplier's 2B."

  defp treatment_reason("not_claimable"), do: "Record this purchase as not claimable this month."

  defp treatment_reason("held"),
    do: "The client holds this document. This does not create a purchase entry."

  defp treatment_reason("not_held"),
    do: "The document has not been received. Any credit-note reversal is retained."

  defp treatment_reason("dismiss_2b"),
    do: "Exclude this GSTR-2B entry because it does not belong to the client."

  defp treatment_reason("block_itc"), do: "Record the recommended credit block."

  defp treatment_reason("allow_itc"),
    do: "Keep the credit after reviewing the flagged eligibility check."

  defp treatment_reason(_), do: nil

  defp treatment_id(action),
    do:
      %{
        "await_2b" => "purchase-await-2b",
        "not_claimable" => "purchase-no-itc",
        "held" => "purchase-document-held",
        "not_held" => "purchase-document-missing",
        "dismiss_2b" => "purchase-not-ours",
        "block_itc" => "purchase-block-itc",
        "allow_itc" => "purchase-allow-itc"
      }[action]

  defp review_reason(%{kind: :gstr2b}, false),
    do: "Reported in GSTR-2B. Import purchases to compare with books."

  defp review_reason(item, _has_books?), do: review_reason(item)

  defp queue_label(%{kind: :gstr2b}, false), do: "Reported in GSTR-2B"
  defp queue_label(item, _has_books?), do: PurchaseWorkspace.label(item)

  defp review_reason(%{bucket: "mismatch"}),
    do: "The purchase record and GSTR-2B are paired, but their amounts differ."

  defp review_reason(%{bucket: "matched"}),
    do: "The purchase record matches GSTR-2B. Matching alone does not establish ITC eligibility."

  defp review_reason(item), do: item.reason

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div
        :if={@item}
        id="purchase-invoice-review"
        class="space-y-block mx-auto w-full max-w-[1400px]"
      >
        <PeriodHeader.period_header
          client={@client}
          period={@period}
          section="Purchases & ITC"
          picker_year={@filing_picker_year}
          path_for_period={
            fn period -> PurchaseWorkspace.list_path(@client_id, period, @filter, "") end
          }
        >
          <.button
            id="purchase-review-back"
            navigate={list_path(assigns) <> "#purchase-open-" <> @item.id}
            variant="ghost"
          >Back to purchases</.button>
          <.button
            :if={@previous}
            id="purchase-review-previous"
            navigate={item_path(assigns, @previous)}
            variant="soft"
          >Previous</.button>
          <.button
            :if={@next}
            id="purchase-review-next"
            navigate={item_path(assigns, @next)}
            variant="soft"
          >Skip for now</.button>
        </PeriodHeader.period_header>

        <div class="gap-block grid lg:grid-cols-[280px_minmax(0,1fr)]">
          <aside aria-label="Review queue" class="space-y-related">
            <p class="text-ui font-medium">{length(@queue)} purchases in this view</p>

            <nav id="purchase-review-queue" class="max-h-[680px] overflow-y-auto">
              <.link
                :for={entry <- @queue}
                id={"purchase-queue-#{entry.id}"}
                navigate={item_path(assigns, entry)}
                aria-current={entry.id == @item.id && "page"}
                class={[
                  "border-rule hover:bg-quiet p-block space-y-related text-ui block border-b",
                  entry.id == @item.id && "bg-interactive"
                ]}
              >
                <p class="font-medium">{entry.invoice_number || "Purchase"}</p>

                <p>{entry.vendor}</p>

                <.context_text>
                  {if pairing_pending?(entry, @items),
                    do: "Pairing needs review",
                    else: queue_label(entry, @has_books?)}
                </.context_text>
              </.link>
            </nav>
          </aside>

          <section class="space-y-block min-w-0" aria-label="Purchase comparison and treatment">
            <div :if={@pairing_pending?} id="purchase-pairing-pending">
              <.callout kind="warning">
                Pairing needs review. This suggested match is unresolved; treatment is unavailable until the pairing is reviewed.
              </.callout>
            </div>

            <div
              :if={Map.get(@item, :treatment) in ~w(claim later exclude split)}
              id="purchase-review-itc-treatment"
            >
              <.callout kind="info">ITC treatment: {itc_label(@item.treatment)}</.callout>
            </div>

            <div class="space-y-related">
              <h2 class="text-h4">{@item.vendor} · {@item.invoice_number || "Purchase review"}</h2>

              <p id="purchase-review-reason" class="text-ui">{review_reason(@item, @has_books?)}</p>

              <div
                :if={Map.get(@item, :flags, []) != []}
                id="purchase-review-checks"
                class="space-y-related"
              >
                <p class="text-ui font-medium">Checks that still need review</p>

                <p :for={flag <- Map.get(@item, :flags, [])} class="text-ui">
                  {flag["reason"] || flag["code"]}
                </p>
              </div>

              <p :if={@item.outcome} id="purchase-review-outcome" class="text-ui">{@item.outcome}</p>

              <.button
                :if={length(Map.get(@item, :treatment_case_ids, [])) == 1 && not @pairing_pending?}
                id="purchase-review-set-treatment"
                variant="soft"
                phx-click="open-itc-treatment"
                disabled={!@can_edit?}
              >Set ITC treatment</.button>
              <.button
                :if={@item.resolved and @item.outcome}
                id="purchase-reopen-decision"
                variant="soft"
                phx-click="decide"
                phx-value-action="reopen"
                disabled={!@can_edit?}
              >Reopen decision</.button>
              <p :if={@signed_off?} id="purchase-review-locked" class="text-ui">
                This month is signed off. Reopen it before changing decisions.
              </p>

              <p :if={!@signed_off? and !@can_edit?} id="purchase-review-readonly" class="text-ui">
                Your role can view this purchase but cannot change decisions.
              </p>
            </div>

            <.form
              :if={@correction_form}
              for={@correction_form}
              id="purchase-values-form"
              phx-submit="save-correction"
              class="space-y-block"
            >
              <p class="text-ui font-medium">Correct purchase values</p>

              <p class="text-ui">
                Enter the amounts supported by the purchase document. Nila keeps the original source and records your correction and reason.
              </p>

              <p :if={@correction_error} id="purchase-correction-error" class="text-error text-ui">
                {@correction_error}
              </p>

              <div class="gap-block grid grid-cols-2 lg:grid-cols-6">
                <.input
                  field={@correction_form[:taxable_paise]}
                  label="Taxable value (₹)"
                  inputmode="decimal"
                  required
                />
                <.input
                  field={@correction_form[:cgst]}
                  label="CGST (₹)"
                  inputmode="decimal"
                  required
                />
                <.input
                  field={@correction_form[:sgst]}
                  label="SGST (₹)"
                  inputmode="decimal"
                  required
                />
                <.input
                  field={@correction_form[:igst]}
                  label="IGST (₹)"
                  inputmode="decimal"
                  required
                />
                <.input
                  :if={@cess_visible?}
                  field={@correction_form[:cess]}
                  label="CESS (₹)"
                  inputmode="decimal"
                  required
                />
                <.input
                  field={@correction_form[:total_paise]}
                  label="Total (₹)"
                  inputmode="decimal"
                  required
                />
              </div>
               <.input field={@correction_form[:reason]} label="Reason for correction" required />
              <div class="gap-related flex">
                <.button id="purchase-save-values" type="submit" disabled={!@can_edit?}>Save correction</.button>
                <.button variant="ghost" type="button" phx-click="cancel-correction">Cancel</.button>
              </div>
            </.form>

            <section :for={{pair, index} <- Enum.with_index(@comparisons)} class="space-y-block">
              <div :if={original_path(assigns, pair.books)} class="space-y-related">
                <.button
                  id={"purchase-original-#{index}"}
                  variant="soft"
                  href={original_path(assigns, pair.books)}
                >Download source Excel</.button>
                <.context_text :if={pair.books["source_sheet"]}>
                  {pair.books["source_filename"]} · {pair.books["source_sheet"]} · Rows {Enum.join(
                    pair.books["source_rows"] || [],
                    ", "
                  )}
                </.context_text>
              </div>

              <p
                :if={source_cess_issue(pair)}
                id={"purchase-comparison-cess-#{index}"}
                class="text-ink-muted text-ui"
              >
                {source_cess_issue(pair)}
              </p>

              <.data_table id={"purchase-comparison-#{index}"} rows={facts(pair)} mode="review">
                <:col :let={row} label="Field" row_header>{row.label}</:col>

                <:col :let={row} label="Purchase records">
                  <span class={row.different? && "bg-warning/10 text-warning font-medium"}>{row.books}</span>
                </:col>

                <:col :let={row} label="GSTR-2B">
                  <span class={row.different? && "bg-warning/10 text-warning font-medium"}>{row.portal}</span>
                  <span :if={row.different?} class="text-ink-muted text-ui"> · Different</span>
                </:col>
              </.data_table>

              <.button
                :if={@item.kind == :books and pair.books}
                id={"purchase-correct-values-#{index}"}
                variant="soft"
                phx-click="start-correction"
                phx-value-books={pair.books["id"]}
                disabled={!@can_edit?}
              >Correct purchase values</.button>
              <p :if={@item.bucket == "mismatch"} class="text-ui">
                Check the purchase document before correcting values; do not copy 2B amounts just to make them match.
              </p>
            </section>

            <div :if={@item.images != []} class="gap-related flex flex-wrap">
              <.button
                :for={{url, index} <- Enum.with_index(@item.images)}
                id={"purchase-source-page-#{index}"}
                variant="soft"
                href={url}
                target="_blank"
                rel="noopener"
              >Source page {index + 1}</.button>
            </div>

            <.form
              :if={not @pairing_pending? and treatments(@item) != []}
              for={to_form(%{}, as: :treatment)}
              id="purchase-treatment-form"
              phx-submit="save-treatment"
              phx-hook=".PurchaseTreatmentKeys"
              class="space-y-block"
            >
              <fieldset disabled={!@can_edit?} class="space-y-related">
                <legend class="text-ui font-medium">
                  {if @item.kind == :gstr2b, do: "Document status", else: "ITC treatment"}
                </legend>

                <div class="gap-related flex flex-wrap">
                  <.button
                    :for={{action, label} <- treatments(@item)}
                    id={treatment_id(action)}
                    type="button"
                    variant={if @treatment == action, do: "primary", else: "soft"}
                    aria-pressed={to_string(@treatment == action)}
                    phx-click="choose-treatment"
                    phx-value-action={action}
                    disabled={!@can_edit?}
                  >{label}</.button>
                </div>
              </fieldset>

              <p :if={@treatment} id="purchase-treatment-reason" class="text-ui">
                {treatment_reason(@treatment)}
              </p>

              <p :if={@treatment_error} id="purchase-treatment-error" class="text-error text-ui">
                {@treatment_error}
              </p>

              <div class="gap-related flex flex-wrap items-center">
                <.button id="purchase-save-next" type="submit" disabled={!@can_edit?}>Save and next</.button>
                <.context_text>Enter on selected treatment · Ctrl/⌘ + Enter to save</.context_text>

                <.button
                  id="purchase-review-skip"
                  navigate={if @next, do: item_path(assigns, @next), else: list_path(assigns)}
                  variant="ghost"
                >Skip for now</.button>
              </div>
            </.form>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".PurchaseTreatmentKeys">
              export default {
                mounted() {
                  this.onKeydown = event => {
                    const selectedTreatment = event.target.closest("button[aria-pressed='true']");
                    if (event.key !== "Enter" || (!(event.ctrlKey || event.metaKey) && !selectedTreatment) || event.altKey || event.shiftKey || event.repeat || event.isComposing || event.defaultPrevented || window.localStorage.getItem("nila-shortcuts-enabled") === "false" || document.querySelector("dialog[open], :popover-open")) return;
                    const submit = this.el.querySelector("button[type='submit']");
                    if (!submit || submit.disabled) return;
                    event.preventDefault();
                    this.el.requestSubmit(submit);
                  };
                  this.el.addEventListener("keydown", this.onKeydown);
                },
                destroyed() { this.el.removeEventListener("keydown", this.onKeydown); }
              }
            </script>
          </section>
        </div>
      </div>

      <.modal
        :if={@itc_form}
        id="purchase-review-treatment-dialog"
        title="Set ITC treatment"
        on_close="cancel-itc-treatment"
        return_focus="#purchase-review-set-treatment"
      >
        <div class="space-y-block">
          <p class="text-ui">
            {@item.vendor} · {@item.invoice_number} · {PurchaseWorkspace.money(@item.tax_paise)} tax
          </p>

          <.callout
            :if={Enum.any?(Map.get(@item, :treatment_lines, []), & &1.treatment_stale?)}
            kind="warning"
          >
            Source amounts changed. Review and save treatment again.
          </.callout>

          <.callout :if={@itc_error} kind="error">{@itc_error}</.callout>

          <.form
            for={@itc_form}
            id="purchase-review-treatment-form"
            phx-submit="apply-itc-treatment"
            class="space-y-block"
            data-shortcut-save
          >
            <.input
              field={@itc_form[:choice]}
              id="purchase-review-treatment-choice"
              type="hidden"
              value={@itc_choice || ""}
            />
            <div class="gap-related flex flex-wrap">
              <.button
                :for={{choice, label} <- review_itc_choices(@period)}
                id={"purchase-review-choice-#{choice}"}
                type="button"
                variant={if @itc_choice == choice, do: "primary", else: "soft"}
                aria-pressed={to_string(@itc_choice == choice)}
                phx-click="choose-itc-treatment"
                phx-value-choice={choice}
                disabled={
                  (choice == "claim" and not Map.get(@item, :claimable?, true)) or
                    (choice in ["claim", "later"] and not is_nil(@cess_issue))
                }
              >{label}</.button>
            </div>

            <p
              :if={not Map.get(@item, :claimable?, true)}
              id="purchase-review-claim-block-reason"
              class="text-ink-muted text-ui"
            >
              Claim is unavailable: {Map.get(@item, :claim_block_reason) ||
                "Review this invoice's checks first."}
            </p>

            <p :if={@cess_issue} id="purchase-review-cess-review" class="text-ink-muted text-ui">
              {@cess_issue}
            </p>

            <.input
              :if={@itc_choice in ["later", "split"]}
              field={@itc_form[:later_reason]}
              id="purchase-review-later-reason"
              type="select"
              label="Why claim later?"
              options={[
                {"Choose a reason", ""}
                | Enum.map(ItcDecisions.reasons("later"), fn {code, label} -> {label, code} end)
              ]}
            />
            <.input
              :if={@itc_choice in ["exclude", "split"]}
              field={@itc_form[:exclude_reason]}
              id="purchase-review-exclude-reason"
              type="select"
              label="Why exclude?"
              options={[
                {"Choose a reason", ""}
                | Enum.map(ItcDecisions.reasons("exclude"), fn {code, label} -> {label, code} end)
              ]}
            />
            <div :if={@itc_choice == "split"} id="purchase-review-split-heads" class="space-y-block">
              <p class="text-ui">
                Enter rupee amounts for each tax head. Each row must add up to its available amount.
              </p>

              <div
                :for={head <- ~w(cgst sgst igst cess)}
                :if={head != "cess" or @cess_visible?}
                class="gap-related grid grid-cols-3"
              >
                <p class="text-ui col-span-3">
                  {String.upcase(head)} available: {PurchaseWorkspace.money(review_head(@item, head))}
                </p>

                <.input
                  :for={part <- ~w(claim later exclude)}
                  type="text"
                  name={"itc[split][#{part}][#{head}]"}
                  value={
                    if head == "cess" and part in ~w(claim later),
                      do: "0.00",
                      else: get_in(@itc_form.params, ["split", part, head]) || "0.00"
                  }
                  disabled={head == "cess" and part in ~w(claim later)}
                  id={"purchase-review-#{head}-#{part}"}
                  label={"#{String.upcase(head)} #{part} (₹)"}
                  inputmode="decimal"
                />
              </div>
            </div>

            <.input
              :if={@itc_choice in ["later", "exclude", "split"]}
              field={@itc_form[:note]}
              id="purchase-review-treatment-note"
              type="textarea"
              label="Note"
              maxlength="1000"
            />
          </.form>
        </div>

        <:footer>
          <.button variant="ghost" phx-click="cancel-itc-treatment">Cancel</.button>
          <.button
            id="purchase-review-apply-treatment"
            type="submit"
            form="purchase-review-treatment-form"
            disabled={!@can_edit?}
          >Save and next</.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  defp review_itc_choices(period),
    do: [
      {"claim",
       "Claim in #{(period <> "-01") |> Date.from_iso8601!() |> Calendar.strftime("%B %Y")}"},
      {"later", "Claim later"},
      {"exclude", "Exclude from ITC"},
      {"split", "Split treatment"}
    ]

  defp itc_label("claim"), do: "Claim this month"
  defp itc_label("later"), do: "Claim later"
  defp itc_label("exclude"), do: "Excluded from ITC"
  defp itc_label("split"), do: "Split treatment"
  defp itc_label(_), do: "Unresolved"

  defp source_cess?(nil), do: false
  defp source_cess?(row), do: (get_in(row, ["tax_paise", "cess"]) || 0) != 0

  defp source_cess_issue(pair) do
    Enum.find_value([pair.books, pair.gstr2b], fn
      nil -> nil
      row -> Nila.Gst.Cess.purchase_issue(row["invoice_date"], row["tax_paise"])
    end)
  end

  defp cess_visible?(item) do
    Enum.any?(Map.get(item, :treatment_lines, []), fn line ->
      Map.get(line.tax_heads, "cess", 0) != 0 or Map.get(line.outstanding_heads, "cess", 0) != 0
    end) or Enum.any?(item.books_members, &source_cess?/1) or source_cess?(item.gstr2b)
  end

  defp review_head(item, head) do
    case Map.get(item, :treatment_lines, []) do
      [line] -> Map.get(line.outstanding_heads, head, 0)
      _ -> 0
    end
  end

  defp review_initial_treatment(line) do
    choice = if line.treatment in ~w(claim later exclude split), do: line.treatment, else: nil

    split =
      for part <- ~w(claim later exclude), into: %{} do
        values =
          for head <- ~w(cgst sgst igst cess), into: %{} do
            paise = get_in(line.treatment_heads || %{}, [part, head]) || 0
            {head, decimal_amount(paise)}
          end

        {part, values}
      end

    {choice,
     %{
       "later_reason" => line.later_reason || "",
       "exclude_reason" => line.exclude_reason || "",
       "note" => line.treatment_note || "",
       "split" => split
     }}
  end
end
