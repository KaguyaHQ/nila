defmodule NilaWeb.Gst.PurchaseInvoiceReviewLive do
  use NilaWeb, :live_view

  alias Nila.Accounts.Policy
  alias Nila.Gst.Purchase.{Resolutions, Review}
  alias NilaWeb.Gst.PurchaseWorkspace

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         item: nil,
         correction_form: nil,
         correction_books_id: nil,
         correction_error: nil
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
      previous: previous,
      next: next,
      can_edit?:
        Policy.can?(socket.assigns.current_scope, :edit_records) and
          not socket.assigns.signed_off?,
      comparisons: comparisons(item, socket.assigns.workings.rows)
    )
  end

  @impl true
  def handle_event("start-correction", %{"books" => books_id}, socket) do
    row = Enum.find(socket.assigns.item.books_members, &(&1["id"] == books_id))

    if row && socket.assigns.can_edit? do
      values = Map.new(~w(taxable_paise total_paise), &{&1, decimal_amount(row[&1] || 0)})

      values =
        Enum.reduce(
          ~w(cgst sgst igst),
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
         {:ok, values, reason} <- correction_values(params),
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

  def handle_event("decide", params, socket) do
    %{current_scope: scope, client_id: client_id, period: period, item: selected} = socket.assigns

    with true <- Policy.can?(scope, :edit_records),
         {:ok, workspace} <- PurchaseWorkspace.load(scope, client_id, period),
         false <- workspace.signed_off?,
         item when not is_nil(item) <- Review.lookup(workspace.items, selected.id),
         {:ok, result} <- decide(workspace.month, item, params, scope.user.id) do
      workspace = %{workspace | month: result.month, workings: result.workings}
      # Decisions can split a group and therefore change its identifier. Return to
      # the same filtered list rather than leaving a stale invoice on screen.
      {:noreply,
       socket
       |> assign(workspace)
       |> put_flash(:info, "Decision saved.")
       |> push_navigate(to: list_path(socket.assigns))}
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

  defp correction_values(params) do
    reason = String.trim(params["reason"] || "")

    parsed =
      for key <- ~w(taxable_paise cgst sgst igst total_paise),
          do: {key, parse_amount(params[key])}

    cond do
      reason == "" ->
        {:error, "Enter a reason for this correction."}

      Enum.any?(parsed, fn {_, value} -> value == :error end) ->
        {:error, "Enter non-negative rupee amounts with no more than two decimal places."}

      true ->
        values = Map.new(parsed)
        expected = values["taxable_paise"] + values["cgst"] + values["sgst"] + values["igst"]

        if abs(values["total_paise"] - expected) > 100 do
          {:error, "Total must equal taxable value plus GST, allowing up to ₹1 for round-off."}
        else
          {:ok,
           %{
             "taxable_paise" => values["taxable_paise"],
             "total_paise" => values["total_paise"],
             "tax_paise" => Map.take(values, ~w(cgst sgst igst))
           }, reason}
        end
    end
  end

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

  defp correction_attrs(row, values, reason) do
    for {field, value} <- values, row[field] != value do
      %{
        "verb" => "correct_field",
        "books_id" => row["id"],
        "payload" => %{"field" => field, "from" => row[field], "to" => value, "reason" => reason}
      }
    end
  end

  defp decide(
         month,
         %{kind: :books} = item,
         %{"action" => action, "books" => books_id, "ref" => ref},
         user_id
       )
       when action in ~w(confirm_pair reject_pair challenge_pair) do
    case Enum.find(item.candidates, &(&1.books_id == books_id and &1.ref == ref)) do
      nil ->
        {:error, :invalid_candidate}

      candidate ->
        record(
          month,
          [
            %{
              "verb" => action,
              "books_id" => candidate.books_id,
              "gstr2b_ref" => candidate.ref,
              "payload" => Review.pair_payload(item, books_id, ref, action)
            }
          ],
          user_id
        )
    end
  end

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
          Map.put(row, "tax_paise", Map.new(~w(cgst sgst igst), &{&1, row[&1 <> "_paise"] || 0}))

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
          {"Total", "total_paise"}
        ] do
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

  defp fact(row, key) when key in ~w(cgst sgst igst),
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
        <.page_header
          title={@item.invoice_number || "Purchase review"}
          eyebrow={@client.name <> " / " <> @period}
        >
          <:actions>
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
            >Next</.button>
          </:actions>
        </.page_header>
        <div :if={@item.claim_state == "not_claiming"} id="purchase-review-claim">
          <.callout kind="info">Not claiming ITC · {@item.claim_reason}</.callout>
        </div>

        <div class="space-y-related">
          <p class="text-ui font-medium">{@item.vendor}</p>
          <p id="purchase-review-reason" class="text-ui">{review_reason(@item)}</p>
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
          <div class="gap-block grid grid-cols-2 lg:grid-cols-5">
            <.input
              field={@correction_form[:taxable_paise]}
              label="Taxable value (₹)"
              inputmode="decimal"
              required
            />
            <.input field={@correction_form[:cgst]} label="CGST (₹)" inputmode="decimal" required />
            <.input field={@correction_form[:sgst]} label="SGST (₹)" inputmode="decimal" required />
            <.input field={@correction_form[:igst]} label="IGST (₹)" inputmode="decimal" required />
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
          <.data_table id={"purchase-comparison-#{index}"} rows={facts(pair)} mode="review">
            <:col :let={row} label="Field" row_header>{row.label}</:col>
            <:col :let={row} label="Purchase records">{row.books}</:col>
            <:col :let={row} label="GSTR-2B">
              <span class={row.different? && "text-warning font-medium"}>{row.portal}</span>
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
          <div :if={pair.ref && !@item.resolved} class="gap-related flex flex-wrap">
            <.button
              id={"purchase-confirm-#{index}"}
              phx-click="decide"
              phx-value-action="confirm_pair"
              phx-value-books={pair.books_id}
              phx-value-ref={pair.ref}
              disabled={!@can_edit?}
            >Same invoice</.button>
            <.button
              id={"purchase-reject-#{index}"}
              variant="soft"
              phx-click="decide"
              phx-value-action="reject_pair"
              phx-value-books={pair.books_id}
              phx-value-ref={pair.ref}
              disabled={!@can_edit?}
            >Keep separate</.button>
          </div>
          <div :if={pair.ref && @item.resolved} class="space-y-related">
            <p :if={@item.bucket == "mismatch"} class="text-ui">
              Confirming the pair does not clear this difference. Check the purchase document before correcting values; do not copy 2B amounts just to make them match.
            </p>
            <.button
              id={"purchase-challenge-#{index}"}
              variant="soft"
              phx-click="decide"
              phx-value-action="challenge_pair"
              phx-value-books={pair.books_id}
              phx-value-ref={pair.ref}
              disabled={!@can_edit?}
            >Review this pairing</.button>
          </div>
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

        <div :if={@item.kind == :books and !@item.resolved} class="space-y-related">
          <p class="text-ui">Matching records does not by itself establish ITC eligibility.</p>
          <div class="gap-related flex flex-wrap">
            <.button
              id="purchase-await-2b"
              variant="soft"
              phx-click="decide"
              phx-value-action="await_2b"
              disabled={!@can_edit?}
            >Keep pending for 2B</.button>
            <.button
              id="purchase-no-itc"
              variant="soft"
              phx-click="decide"
              phx-value-action="not_claimable"
              disabled={!@can_edit?}
            >No ITC this month</.button>
          </div>
        </div>
        <div :if={@item.kind == :gstr2b and !@item.resolved} class="space-y-related">
          <p class="text-ui">
            Confirm whether the client holds this document. This does not create a purchase entry.
          </p>
          <div class="gap-related flex flex-wrap">
            <.button
              id="purchase-document-held"
              phx-click="decide"
              phx-value-action="held"
              disabled={!@can_edit?}
            >Client holds document</.button>
            <.button
              id="purchase-document-missing"
              variant="soft"
              phx-click="decide"
              phx-value-action="not_held"
              disabled={!@can_edit?}
            >Document not received</.button>
            <.button
              id="purchase-not-ours"
              variant="soft"
              phx-click="decide"
              phx-value-action="dismiss_2b"
              disabled={!@can_edit?}
            >Not ours</.button>
          </div>
        </div>
        <div :if={@item.kind == :itc and !@item.resolved} class="gap-related flex flex-wrap">
          <.button
            id="purchase-block-itc"
            phx-click="decide"
            phx-value-action="block_itc"
            disabled={!@can_edit?}
          >Block credit</.button>
          <.button
            id="purchase-allow-itc"
            variant="soft"
            phx-click="decide"
            phx-value-action="allow_itc"
            disabled={!@can_edit?}
          >Keep credit</.button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
