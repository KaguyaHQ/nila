defmodule NilaWeb.Gst.MonthLive do
  use NilaWeb, :live_view

  @moduledoc """
  The client-month workbench: the one room where a month gets closed.
  """

  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Chase.CompletenessSender
  alias Nila.Gst.Filing.{Calendar, Signoffs}
  alias Nila.Gst.Intake.{Confirmations, DumpWorker, Dumps, Preconditions}
  alias Nila.Gst.Issues
  alias Nila.Gst.Purchase.{Groups, Reconciliation, Register, Resolutions, Review}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Account
  alias Nila.Gst.Sales.Review, as: SalesReview
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias Nila.Gst.WorkQueue
  alias Nila.Eval.Gstr1Diff

  alias NilaWeb.Components.Gst.Month.{
    Arrivals,
    Evidence,
    Filing,
    Precondition,
    Purchase,
    Sales,
    Verdict,
    Workings
  }

  alias NilaWeb.Components.Gst.Review.{PurchaseLive, SalesLive}
  alias NilaWeb.Gst.PeriodOptions

  @impl true
  def mount(%{"client_id" => client_id, "period" => period}, _session, socket) do
    org = socket.assigns.current_scope.current_org

    with true <- org != nil,
         {:ok, client} <- Clients.get_client(org.id, client_id),
         :ok <- maybe_subscribe(socket, org.id),
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

  defp maybe_subscribe(socket, org_id) do
    if connected?(socket), do: PurchaseMonths.subscribe(org_id), else: :ok
  end

  # A month with no derived side is still a real page when documents arrived and
  # were deliberately not derived — a packet awaiting confirmation is exactly
  # that, and bouncing the reviewer to Today would leave the question
  # unanswerable.
  defp try_load(socket, client, period) do
    org_id = socket.assigns.current_scope.current_org.id
    purchase = fetch_or_nil(PurchaseMonths.get_by_period(org_id, client.id, period))
    sales = fetch_or_nil(SalesMonths.get_by_period(org_id, client.id, period))
    dumps = Dumps.list(org_id, client.id, period)

    if purchase || sales || dumps != [] do
      socket
      |> assign(:client, client)
      |> assign(:period, period)
      |> assign(:page_title, "#{client.name} · #{period_label(period)}")
      |> assign(:purchase_review_route, nil)
      |> assign(:sales_review_route, nil)
      |> assign(:last_reviewed_inum, nil)
      |> assign(:visited_inums, MapSet.new())
      |> assign(:expanded_nodes, MapSet.new())
      |> assign(:rippled, MapSet.new())
      |> assign(:ripple_seq, 0)
      |> assign(:duplicate_review_target, nil)
      |> assign(:show_completeness_override, false)
      |> assign(:completeness_override_form, to_form(%{"reason" => ""}, as: :override))
      |> assign(:show_chase_history, false)
      |> assign(:precondition_choice, nil)
      |> assign(:can_sign_off, Policy.can?(socket.assigns.current_scope, :sign_off))
      |> assign_month(purchase, sales)
    end
  end

  @impl true
  def handle_params(
        %{"lane" => "purchase"} = params,
        _uri,
        %{assigns: %{live_action: :review, purchase_month: month}} = socket
      )
      when not is_nil(month) do
    review = Review.project(socket.assigns.purchase_workings, month: month)
    route = Review.route_state(review, params["item"], params["scope"])

    {:noreply,
     assign(socket,
       purchase_review_route: route,
       sales_review_route: nil
     )}
  end

  def handle_params(
        %{"lane" => "sales"} = params,
        _uri,
        %{assigns: %{live_action: :review, sales_month: month}} = socket
      )
      when not is_nil(month) do
    review = SalesReview.build(socket.assigns.sales_workings)
    route = SalesReview.route_state(review, params["item"], params["scope"])
    selected = SalesReview.lookup(review.all, route.item)
    focus = valid_review_focus(selected, params["focus"])
    route = Map.put(route, :focus, focus)

    socket =
      assign(socket,
        purchase_review_route: nil,
        sales_review_route: route,
        last_reviewed_inum: route.item || socket.assigns.last_reviewed_inum,
        visited_inums:
          if(route.item,
            do: MapSet.put(socket.assigns.visited_inums, route.item),
            else: socket.assigns.visited_inums
          )
      )

    if canonical_sales_route?(params, route) do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: sales_review_path(socket, route), replace: true)}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :review}} = socket) do
    {:noreply, push_patch(socket, to: month_path(socket))}
  end

  def handle_params(
        %{"invoice" => identifier},
        _uri,
        %{assigns: %{live_action: :index, sales_month: month}} = socket
      )
      when not is_nil(month) do
    source_id = valid_invoice_number(socket.assigns.invoices, identifier)
    review = SalesReview.build(socket.assigns.sales_workings)
    route = SalesReview.route_state(review, source_id, nil) |> Map.put(:focus, nil)

    {:noreply, push_patch(socket, to: sales_review_path(socket, route), replace: true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       purchase_review_route: nil,
       sales_review_route: nil
     )}
  end

  defp valid_review_focus(nil, _focus), do: nil
  defp valid_review_focus(_item, nil), do: nil

  defp valid_review_focus(item, focus) do
    if Enum.any?(item.issues, &(SalesWorkings.issue_key(&1) == focus)), do: focus
  end

  defp canonical_sales_route?(params, route) do
    params["item"] == route.item and params["scope"] == to_string(route.scope) and
      params["focus"] == route.focus
  end

  defp valid_invoice_number(_invoices, nil), do: nil

  defp valid_invoice_number(invoices, identifier) do
    case Enum.find(invoices, &(&1["id"] == identifier)) do
      %{} = invoice ->
        invoice["id"]

      nil ->
        case Enum.filter(invoices, fn invoice ->
               invoice["invoice_number"] == identifier or invoice["pristine_inum"] == identifier
             end) do
          [invoice] -> invoice["id"] || identifier
          _ambiguous_or_missing -> nil
        end
    end
  end

  defp fetch_or_nil({:ok, value}), do: value
  defp fetch_or_nil({:error, :not_found}), do: nil

  # Not "resolve the issues" — these cannot be resolved by a reviewer, only by
  # the return learning the table the document belongs in. Say which document,
  # and say the return cannot hold it.
  defp blocked_message(codes) do
    "This month holds " <>
      Enum.map_join(codes, ", ", &blocked_document/1) <>
      ", which this return has no section for. Filing it as a regular invoice would be wrong, so it cannot be signed."
  end

  defp blocked_document("credit_note_unsupported"), do: "a credit note"
  defp blocked_document("debit_note_unsupported"), do: "a debit note"
  defp blocked_document("export_supply_unsupported"), do: "an export or SEZ supply"
  defp blocked_document("outward_reverse_charge_unsupported"), do: "a reverse-charge supply"
  defp blocked_document("b2c_supply_unsupported"), do: "a bill with no buyer GSTIN"
  defp blocked_document("cess_unsupported"), do: "a cess-bearing supply"
  defp blocked_document(code), do: code

  defp completeness_error(:open), do: "not confirmed"
  defp completeness_error(:client_no), do: "still open"
  defp completeness_error(:stale), do: "stale after later or unresolved intake"

  defp reload(socket) do
    %{client: client, period: period} = socket.assigns
    org_id = socket.assigns.current_scope.current_org.id
    purchase = fetch_or_nil(PurchaseMonths.get_by_period(org_id, client.id, period))
    sales = fetch_or_nil(SalesMonths.get_by_period(org_id, client.id, period))
    assign_month(socket, purchase, sales)
  end

  defp assign_month(socket, purchase, sales) do
    socket
    |> assign_purchase(purchase)
    |> assign_dumps()
    |> assign_sales(sales)
    |> assign_verdict(purchase, sales)
  end

  defp assign_dumps(socket) do
    %{client: client, period: period} = socket.assigns
    org_id = socket.assigns.current_scope.current_org.id
    dumps = Dumps.list(org_id, client.id, period)
    in_question = Enum.find(dumps, &(&1.status == "needs_confirmation"))

    socket
    |> assign(:dumps, dumps)
    |> assign(:sales_dumps, Enum.filter(dumps, &(&1.kind in ~w(sales filed_gstr1))))
    |> assign(:purchase_dumps, Enum.filter(dumps, &(&1.kind in ~w(purchase gstr2b))))
    |> assign(:precondition_dump, in_question)
    |> assign(
      :move_options,
      in_question && PeriodOptions.for_client(org_id, client.id, except: period)
    )
    # Deliberately not "is there an extracted gstr2b dump": that asks about our
    # intake plumbing, and a month reconciled by any other route then reads as
    # "nothing reconciles until the 2B is in" above its own matched rows. The
    # recon is the evidence. The dump is only a fallback for a 2B that arrived
    # and produced no matches at all.
    |> assign(
      :gstr2b_in,
      Reconciliation.reconciled_against_2b?(
        socket.assigns.purchase_month && socket.assigns.purchase_month.recon
      ) or
        Enum.any?(dumps, &(&1.kind == "gstr2b" and &1.status == "extracted"))
    )
    |> assign(:sales_pages_read, Dumps.source_page_count(org_id, client.id, period, "sales"))
    |> assign(
      :purchase_pages_read,
      Dumps.source_page_count(org_id, client.id, period, "purchase")
    )
    # What the month actually works off. A discarded upload and a 2B that a
    # later one replaced are history; counting them as files received overstates
    # what the client supplied.
    |> assign(
      :active_purchase_dumps,
      Dumps.effective(org_id, client.id, period, "purchase") ++
        Dumps.effective(org_id, client.id, period, "gstr2b")
    )
    |> assign(:superseded_2b_ids, superseded_2b_ids(dumps))
    |> assign(:asks, Chase.list_asks(org_id, client.id, period))
    |> assign(:open_period, Calendar.closeable_period(Date.utc_today()))
    |> assign(
      :attention_dumps,
      Enum.filter(
        dumps,
        &(&1.status in ~w(received extracting held failed after_filing needs_confirmation))
      )
    )
  end

  defp superseded_2b_ids(dumps) do
    dumps
    |> Enum.filter(&(&1.kind == "gstr2b" and &1.status == "extracted"))
    |> Enum.drop(-1)
    |> MapSet.new(& &1.id)
  end

  defp assign_purchase(socket, purchase, workings \\ nil)

  defp assign_purchase(socket, nil, _workings) do
    socket
    |> assign(:purchase_month, nil)
    |> assign(:purchase_workings, nil)
    |> assign(:gstr3b_signoff, nil)
    |> assign(:rows, [])
    |> assign(:stats, nil)
    |> assign(:document_flags, [])
    |> assign(:gstr3b, nil)
    |> assign(:itc, nil)
  end

  defp assign_purchase(socket, purchase, provided_workings) do
    signoff = fetch_or_nil(Signoffs.latest_signoff(purchase.id))
    live_workings = provided_workings || Resolutions.workings(purchase)

    workings =
      case signoff do
        nil -> live_workings
        signoff -> signed_purchase_workings(signoff.snapshot, live_workings)
      end

    socket
    |> assign(:purchase_month, purchase)
    |> assign(:purchase_workings, workings)
    |> assign(:gstr3b_signoff, signoff)
    |> assign(:rows, build_rows(workings.rows, purchase, workings.groups))
    |> assign(:stats, Register.stats(workings.summary))
    |> assign(:document_flags, workings.summary["document_flags"] || [])
    |> assign(:gstr3b, workings.gstr3b)
    |> assign(:itc, workings.itc)
  end

  defp signed_purchase_workings(snapshot, fallback) do
    case snapshot["review"] do
      %{} = review ->
        recon = review["recon"] || %{}

        %{
          baseline: review["baseline"] || %{},
          recon: recon,
          groups: Groups.build(recon),
          decisions: review["decisions"] || %{},
          accepted_reasons: review["accepted_reasons"] || %{},
          gstr2b_decisions: review["gstr2b_decisions"] || %{},
          document_attestation: restore_attestation(review["document_attestation"]),
          rows: snapshot["rows"],
          summary: snapshot["summary"],
          gstr3b: snapshot["gstr3b"],
          itc: snapshot["itc"]
        }

      _legacy ->
        %{
          fallback
          | rows: snapshot["rows"],
            summary: snapshot["summary"],
            gstr3b: snapshot["gstr3b"],
            itc: snapshot["itc"]
        }
    end
  end

  defp restore_attestation(nil), do: nil

  defp restore_attestation(attestation) do
    %{
      target: attestation["target"] || attestation[:target],
      answer: attestation["answer"] || attestation[:answer],
      count: attestation["count"] || attestation[:count],
      tax_paise: attestation["tax_paise"] || attestation[:tax_paise]
    }
  end

  defp build_rows(rows, purchase, groups) do
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
      |> Map.put("review_item", review_item(row, groups))
      |> Map.put("dom_id", row_dom_id(row, index))
    end)
  end

  defp review_item(%{"id" => id}, _groups) when is_binary(id), do: id

  defp review_item(%{"gstr2b" => counterpart}, groups) when is_map(counterpart),
    do: counterpart_group_key(counterpart, groups)

  defp review_item(%{"bucket" => "in_2b_not_books"} = row, groups),
    do: counterpart_group_key(row, groups)

  defp review_item(_row, _groups), do: nil

  defp counterpart_group_key(counterpart, groups) do
    ref = Reconciliation.gstr2b_ref(counterpart)

    group =
      Enum.find(
        groups,
        &Enum.any?(&1.counterparts, fn g -> Reconciliation.gstr2b_ref(g) == ref end)
      )

    group && group.key
  end

  defp row_dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp row_dom_id(_row, index), do: "gst-row-idx-#{index}"

  defp assign_sales(socket, sales, workings \\ nil)

  defp assign_sales(socket, nil, _workings) do
    socket
    |> assign(:sales_month, nil)
    |> assign(:sales_workings, nil)
    |> assign(:sales_decisions, %{})
    |> assign(:r1_signoff, nil)
    |> assign(:invoices, [])
    |> assign(:active_invoices, [])
    |> assign(:issues_by_invoice, %{})
    |> assign(:month_issues, [])
    |> assign(:flagged, MapSet.new())
    |> assign(:derived_gstr1, nil)
    |> assign(:gstr1_diff, nil)
    |> assign(:accepted_diffs, MapSet.new())
    |> assign(:sales_account, nil)
    |> assign(:sales_completeness, :open)
    |> assign(:sales_confirmation, nil)
    |> assign(:open_issue_count, 0)
    |> assign(:reviewable, false)
  end

  defp assign_sales(socket, sales, provided_workings) do
    signoff = fetch_or_nil(Signoffs.latest_gstr1_signoff(sales.id))

    workings =
      provided_workings ||
        case signoff do
          # Invoice-less months still have completeness questions. A hand-built
          # empty projection would offer approval over a server-side rejection.
          nil ->
            SalesResolutions.workings(sales)

          signoff ->
            source = signoff.snapshot["invoices"]
            active = Enum.reject(source, &Map.has_key?(&1, "duplicate_copy"))

            %{
              source_invoices: source,
              active_invoices: active,
              printed_active_invoices: signoff.snapshot["printed_invoices"],
              issues: Issues.normalize_all(signoff.snapshot["issues"]),
              flagged: MapSet.new(),
              derived: signoff.snapshot["derived"]
            }
        end

    source_invoices = workings.source_invoices
    active_invoices = workings.active_invoices
    issues = workings.issues
    flagged = workings.flagged
    derived = workings.derived

    invoices =
      sales.invoices
      |> Enum.zip(source_invoices)
      |> Enum.map(fn {pristine, effective} ->
        effective
        |> Map.put("pristine_inum", pristine["invoice_number"])
        |> Map.put("image_urls", sales_image_urls(effective, sales))
      end)

    {month_issues, invoice_issues} = Enum.split_with(issues, &is_nil(&1["source_id"]))
    org_id = sales.org_id
    completeness = Confirmations.status(org_id, sales.client_id, sales.period)
    confirmation = fetch_or_nil(Confirmations.latest(org_id, sales.client_id, sales.period))

    account =
      Account.summarize(workings, %{
        files: length(Dumps.effective(org_id, sales.client_id, sales.period, "sales")),
        pages_read: socket.assigns.sales_pages_read
      })

    filed = filed_gstr1(sales)

    socket
    |> assign(:sales_month, sales)
    |> assign(:sales_workings, workings)
    |> assign(:sales_decisions, SalesResolutions.latest_decisions(sales.id))
    |> assign(:r1_signoff, signoff)
    |> assign(:invoices, invoices)
    |> assign(:active_invoices, active_invoices)
    |> assign(:issues_by_invoice, Enum.group_by(invoice_issues, & &1["source_id"]))
    |> assign(:month_issues, month_issues)
    |> assign(:flagged, flagged)
    |> assign(:derived_gstr1, derived)
    |> assign(:gstr1_diff, filed && derived && Gstr1Diff.rows(derived, filed))
    |> assign(:accepted_diffs, SalesResolutions.accepted_differences(sales))
    |> assign(:sales_account, account)
    |> assign(:sales_completeness, completeness)
    |> assign(:sales_confirmation, confirmation)
    |> assign(:open_issue_count, account.issues.required_count)
    |> assign(:reviewable, SalesWorkings.reviewable?(issues))
  end

  # Present only when a portal download actually landed — the column is nil on
  # every month that never loaded one, and an empty map is not a return.
  defp filed_gstr1(%{filed_gstr1: filed}) when is_map(filed) and filed != %{}, do: filed
  defp filed_gstr1(_sales), do: nil

  # `"image"` is the invoice's own answer to "which page was this read from" and
  # the only one worth trusting. Guessing a basename from `"page"` — as this did
  # — fabricates a URL for a file nobody stored whenever extraction had no page
  # to name, which is exactly when the guess is most likely to be wrong.
  defp sales_image_urls(invoice, sales) do
    case invoice["image"] do
      basename when is_binary(basename) ->
        [~p"/gstr1/#{sales.client_id}/#{sales.period}/evidence/#{basename}"]

      _none ->
        []
    end
  end

  # The month is a pair of tracks, and exactly one of them owns the page's one
  # door. Deriving the pair here (from the same WorkQueue projection Today
  # folds) is what stops this page from inventing a second answer.
  defp toggle(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  defp assign_verdict(socket, purchase, sales) do
    %{stats: stats, r1_signoff: r1_signoff, gstr3b_signoff: gstr3b_signoff} = socket.assigns
    today = Date.utc_today()

    tracks =
      WorkQueue.track_states(%{
        purchase: purchase,
        sales: sales,
        need_decision: (stats && stats.need_decision) || 0,
        gstr2b_in: socket.assigns.gstr2b_in,
        gstr2b_available: Calendar.status(socket.assigns.period, today).gstr2b_available?,
        r1_signed: r1_signoff != nil,
        r1_filed: sales != nil and sales.filed_at != nil,
        gstr3b_signed: gstr3b_signoff != nil,
        gstr3b_filed: purchase != nil and purchase.filed_at != nil,
        sales_complete: socket.assigns.sales_completeness == :complete
      })

    facts = %{
      tracks: tracks,
      stats: stats,
      gstr3b: socket.assigns.gstr3b,
      purchase_month: purchase,
      sales_month: sales,
      open_issue_count: socket.assigns.open_issue_count,
      r1_signoff: r1_signoff,
      gstr3b_signoff: gstr3b_signoff,
      can_sign_off: socket.assigns.can_sign_off,
      attention_dumps: socket.assigns.attention_dumps,
      open_period: socket.assigns.open_period,
      client: socket.assigns.client,
      period: socket.assigns.period,
      today: today
    }

    socket
    |> assign(:tracks, tracks)
    |> assign(:blocking_state, WorkQueue.fold_state(tracks))
    |> assign(:verdict, Verdict.resolve(facts))
  end

  @impl true
  def handle_info(
        {:gst_dump_progress, _dump_id, client_id, period, _kind, _message},
        %{assigns: %{client: %{id: client_id}, period: period}} = socket
      ) do
    {:noreply, reload(socket)}
  end

  def handle_info({:purchase_review_refresh, item_id, month, workings}, socket) do
    current = socket.assigns.purchase_review_route

    socket =
      socket
      |> assign_purchase(month, workings)
      |> assign_verdict(month, socket.assigns.sales_month)

    review = Review.project(socket.assigns.purchase_workings, month: month)
    route = Review.route_state(review, item_id, current.scope)
    socket = assign(socket, :purchase_review_route, route)

    if route == current do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: purchase_review_path(socket, route), replace: true)}
    end
  end

  def handle_info({:sales_review_refresh, month, workings, requested}, socket) do
    old_derived = socket.assigns.derived_gstr1

    socket =
      socket
      |> assign_sales(month, workings)
      |> assign_verdict(socket.assigns.purchase_month, month)
      |> ripple(old_derived)

    case socket.assigns.sales_review_route do
      nil ->
        {:noreply, socket}

      current ->
        review = SalesReview.build(socket.assigns.sales_workings)
        route = SalesReview.route_state(review, requested.item, requested.scope)
        selected = SalesReview.lookup(review.all, route.item)
        route = Map.put(route, :focus, valid_review_focus(selected, requested.focus))
        socket = assign(socket, :sales_review_route, route)

        if route == current do
          {:noreply, socket}
        else
          {:noreply, push_patch(socket, to: sales_review_path(socket, route), replace: true)}
        end
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Contributor rows still use this event; the register itself patches directly.
  @impl true
  def handle_event("select-invoice", %{"inum" => identifier}, socket) do
    case valid_invoice_number(socket.assigns.invoices, identifier) do
      nil ->
        {:noreply, socket}

      source_id ->
        review = SalesReview.build(socket.assigns.sales_workings)
        route = SalesReview.route_state(review, source_id, nil) |> Map.put(:focus, nil)
        {:noreply, push_patch(socket, to: sales_review_path(socket, route))}
    end
  end

  def handle_event("open-duplicate-review", %{"target" => target}, socket),
    do: {:noreply, assign(socket, :duplicate_review_target, target)}

  def handle_event("close-duplicate-review", _params, socket),
    do: {:noreply, assign(socket, :duplicate_review_target, nil)}

  def handle_event("resolve-duplicate-copies", %{"source" => retained_source_id}, socket) do
    case SalesResolutions.exclude_duplicate_copies(
           socket.assigns.sales_month,
           retained_source_id,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, _resolutions} ->
        {:noreply,
         socket
         |> assign(:duplicate_review_target, nil)
         |> reload()
         |> put_flash(:info, "Duplicate source copies excluded from the GSTR-1 draft.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Those sources are no longer one duplicate group.")}
    end
  end

  # Which workings buckets are open lives here rather than in an inline style,
  # so a re-render somewhere else on the page cannot collapse them.
  def handle_event("toggle-workings-node", %{"node" => node}, socket),
    do: {:noreply, update(socket, :expanded_nodes, &toggle(&1, node))}

  # Comma-joined, because one issue can cover several bad codes since per-line
  # findings collapse into a single card. Expanding only the first left the
  # review gate unsatisfiable — or worse, satisfied without the other codes'
  # rows ever being shown.
  def handle_event("review-hsn-issue", %{"code" => code}, socket) do
    nodes =
      code
      |> String.split(",", trim: true)
      |> Enum.flat_map(&Workings.hsn_node_ids(socket.assigns.active_invoices, &1))

    {:noreply,
     update(socket, :expanded_nodes, fn expanded ->
       MapSet.union(expanded, MapSet.new(nodes))
     end)}
  end

  def handle_event("open-completeness-override", _params, socket),
    do:
      {:noreply,
       assign(socket,
         show_completeness_override: true,
         completeness_override_form: to_form(%{"reason" => ""}, as: :override)
       )}

  def handle_event("close-completeness-override", _params, socket),
    do: {:noreply, assign(socket, :show_completeness_override, false)}

  def handle_event("send-completeness-request", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case CompletenessSender.enqueue_now(org_id, socket.assigns.client.id, socket.assigns.period) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:show_completeness_override, false)
         |> put_flash(:info, "WhatsApp confirmation request queued.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "The WhatsApp request could not be queued.")}
    end
  end

  def handle_event("save-completeness-override", %{"override" => params}, socket) do
    case Confirmations.record_override(
           socket.assigns.current_scope,
           socket.assigns.client.id,
           socket.assigns.period,
           params
         ) do
      {:ok, _confirmation} ->
        {:noreply,
         socket
         |> assign(:show_completeness_override, false)
         |> reload()
         |> put_flash(:info, "Sales collection completeness overridden with an audit reason.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :completeness_override_form,
           to_form(%{changeset | action: :insert}, as: :override)
         )}

      {:error, :not_allowed} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to override completeness.")}
    end
  end

  def handle_event("open-chase-history", _params, socket),
    do: {:noreply, assign(socket, :show_chase_history, true)}

  def handle_event("close-chase-history", _params, socket),
    do: {:noreply, assign(socket, :show_chase_history, false)}

  # The cess question is answered either way through this one verb: the reviewer
  # looked, and that is the durable fact. Which answer he gave rides as payload,
  # and "cess applies" is what uncovers the blocking capability gap.
  def handle_event("confirm_issue", %{"target" => target, "answer" => answer}, socket)
      when answer in ~w(no_cess cess_applies),
      do:
        record(socket, %{
          "verb" => "confirm_issue",
          "target" => target,
          "payload" => %{"answer" => answer}
        })

  def handle_event("confirm_issue", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "confirm_issue", "target" => target})

  def handle_event("undo", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "reopen", "target" => target})

  def handle_event("attest-completeness", %{"target" => target, "answer" => answer}, socket)
      when answer in ~w(no yes unknown) do
    record(socket, %{
      "verb" => "confirm_issue",
      "target" => target,
      "payload" => %{"answer" => answer}
    })
  end

  def handle_event("accept_difference", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "accept_difference", "target" => target})

  def handle_event("r1-sign-off", _params, socket) do
    case Signoffs.sign_off_gstr1(socket.assigns.sales_month, socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "GSTR-1 approved.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to approve.")}

      {:error, :not_reviewed} ->
        {:noreply, put_flash(socket, :error, "Open checks remain — resolve them first.")}

      {:error, :already_signed} ->
        {:noreply, put_flash(socket, :error, "This GSTR-1 is already approved.")}

      {:error, {:sales_intake_incomplete, status}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Sales collection is #{completeness_error(status)} — get a current client confirmation or record a senior override."
         )}

      {:error, {:blocking_issues, codes}} ->
        {:noreply, put_flash(socket, :error, blocked_message(codes))}
    end
  end

  def handle_event("r1-reopen-signoff", _params, socket) do
    case Signoffs.reopen(socket.assigns.r1_signoff, socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Approval reopened — the month can be worked again.")}

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
        {:noreply, filed_flash(socket, "GSTR-1 marked filed.")}

      {:error, :not_signed} ->
        {:noreply, put_flash(socket, :error, "Sign off the GSTR-1 before marking it filed.")}

      {:error, :already_filed} ->
        {:noreply, reload(socket)}
    end
  end

  def handle_event("3b-sign-off", _params, socket) do
    case Signoffs.sign_off(socket.assigns.purchase_month, socket.assigns.current_scope) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Month signed off.")}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to sign off this month.")}

      {:error, :already_signed} ->
        {:noreply, put_flash(socket, :error, "This month is already signed off.")}

      {:error, :not_reviewed} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(
           :error,
           "The register still has unsettled rows — work the decisions and collect the missing bills first."
         )}

      {:error, :documents_unattested} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(
           :error,
           "Confirm whether the client holds tax invoices for the supplies with no bill on file — the credit cannot be claimed unanswered."
         )}

      {:error, {:sales_intake_incomplete, status}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Sales collection is #{completeness_error(status)} — GSTR-3B cannot be signed yet."
         )}
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

  def handle_event("precondition-choose", %{"answer" => answer}, socket)
      when answer in ~w(move keep discard),
      do: {:noreply, assign(socket, :precondition_choice, answer)}

  def handle_event("precondition-cancel", _params, socket),
    do: {:noreply, assign(socket, :precondition_choice, nil)}

  # Answering is a routing decision, not a data edit: the dump's `period` was
  # the thing that was wrong, and nothing about the extraction is re-run. A move
  # hands the packet back to the worker, which runs the same wall check every
  # arrival runs — a signed destination holds it, and that is the correct,
  # already-built outcome.
  def handle_event("precondition-answer", params, socket) do
    org_id = socket.assigns.current_scope.current_org.id
    user_id = socket.assigns.current_scope.user.id

    with %{id: dump_id} <- socket.assigns.precondition_dump,
         {:ok, dump} <- Dumps.fetch(org_id, dump_id) do
      answer_precondition(socket, dump, params, user_id)
    else
      _ -> {:noreply, reload(socket)}
    end
  end

  def handle_event("release-dump", %{"dump-id" => dump_id}, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    with {:ok, %{status: "held"} = dump} <- Dumps.fetch(org_id, dump_id) do
      released = Dumps.release(dump)
      {:ok, _} = Oban.insert(DumpWorker.new(%{dump_id: released.id}))

      {:noreply,
       socket |> reload() |> put_flash(:info, "Dump released — the month reworks with it now.")}
    else
      _ -> {:noreply, socket}
    end
  end

  # Senior-only, because it clears exactly the block that
  # `Confirmations.record_override/4` clears — and that is `:sign_off`-only with
  # a written reason. Leaving this open let any member reach the same outcome in
  # one click, which is a cheaper route around a control that was made
  # senior-only on purpose.
  def handle_event("abandon-dump", %{"dump-id" => dump_id}, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    with true <- socket.assigns.can_sign_off,
         {:ok, %{status: "failed"} = dump} <- Dumps.fetch(org_id, dump_id),
         {:ok, _abandoned} <- Dumps.abandon_failed(dump, socket.assigns.current_scope.user.id) do
      {:noreply,
       socket
       |> reload()
       |> put_flash(:info, "Stopped waiting for that packet. The month can be worked without it.")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Only a senior can stop waiting for a packet.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("3b-mark-filed", params, socket) do
    case Signoffs.mark_filed(
           socket.assigns.purchase_month,
           socket.assigns.current_scope,
           arn(params)
         ) do
      {:ok, _} ->
        {:noreply, filed_flash(socket, "GSTR-3B marked filed.")}

      {:error, :not_signed} ->
        {:noreply, put_flash(socket, :error, "Sign off the month before marking it filed.")}

      {:error, :already_filed} ->
        {:noreply, reload(socket)}
    end
  end

  defp answer_precondition(socket, dump, %{"answer" => "move", "period" => period}, user_id) do
    case Preconditions.move(dump, period, user_id) do
      {:ok, moved} ->
        {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: moved.id}))

        {:noreply,
         socket
         |> put_flash(:info, "Packet moved to #{period_label(period)}.")
         |> push_navigate(to: ~p"/gst/#{moved.client_id}/#{moved.period}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Pick the month this packet belongs to.")}
    end
  end

  defp answer_precondition(socket, dump, %{"answer" => "keep"} = params, user_id) do
    case Preconditions.keep(dump, params["reason"], user_id) do
      {:ok, kept} ->
        {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: kept.id}))

        {:noreply,
         socket
         |> assign(:precondition_choice, nil)
         |> reload()
         |> put_flash(
           :info,
           "Kept in #{period_label(kept.period)} — the month reworks with it now."
         )}

      {:error, :reason_required} ->
        {:noreply, put_flash(socket, :error, "Say why this packet belongs here.")}

      {:error, _reason} ->
        {:noreply, reload(socket)}
    end
  end

  defp answer_precondition(socket, dump, %{"answer" => "discard"}, user_id) do
    case Preconditions.discard(dump, user_id) do
      {:ok, _discarded} ->
        {:noreply,
         socket
         |> assign(:precondition_choice, nil)
         |> reload()
         |> put_flash(:info, "Packet discarded. It stays on the paper trail.")}

      {:error, _reason} ->
        {:noreply, reload(socket)}
    end
  end

  defp answer_precondition(socket, _dump, _params, _user_id), do: {:noreply, reload(socket)}

  defp filed_flash(socket, return_message) do
    socket = reload(socket)

    put_flash(
      socket,
      :info,
      if(socket.assigns.blocking_state == :done, do: "Month closed.", else: return_message)
    )
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
        old_derived = socket.assigns.derived_gstr1
        {:noreply, socket |> reload() |> ripple(old_derived)}

      {:error, :signed_off} ->
        {:noreply,
         put_flash(socket, :error, "This GSTR-1 is signed off — a senior must reopen it first.")}
    end
  end

  # The ripple sequence alternates the animation class so a second correction
  # restarts the glow on a node already at rest; it only advances when
  # something actually changed, so confirming an issue disturbs nothing.
  defp ripple(socket, old_derived) do
    changed = Workings.changed_nodes(old_derived, socket.assigns.derived_gstr1)

    if MapSet.size(changed) == 0 do
      assign(socket, :rippled, changed)
    else
      socket
      |> assign(:rippled, changed)
      |> assign(:ripple_seq, socket.assigns.ripple_seq + 1)
    end
  end

  defp month_path(socket) do
    %{client: client, period: period} = socket.assigns
    ~p"/gst/#{client.id}/#{period}"
  end

  defp purchase_review_path(socket, route) do
    params = %{"item" => route.item, "scope" => to_string(route.scope)}
    month_path(socket) <> "/review/purchase?" <> URI.encode_query(params)
  end

  defp sales_review_path(socket, route) do
    params =
      %{"item" => route.item, "scope" => to_string(route.scope), "focus" => route[:focus]}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    month_path(socket) <> "/review/sales?" <> URI.encode_query(params)
  end

  @impl true
  def render(assigns) do
    duplicate_issue =
      Enum.find(assigns.month_issues, fn issue ->
        SalesWorkings.issue_key(issue) == assigns.duplicate_review_target
      end)

    assigns = assign(assigns, :duplicate_issue, duplicate_issue)

    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
    >
      <div id="month-page" class="space-y-region mx-auto max-w-7xl">
        <Verdict.verdict verdict={@verdict} client={@client} period={@period} />

        <Precondition.question
          :if={@verdict[:question]}
          dump={@verdict.question.dump}
          finding={@verdict.question.finding}
          period={@period}
          choice={@precondition_choice}
          period_options={@move_options || []}
        />

        <Arrivals.chase_history_link asks={@asks} />

        <div
          :if={
            (is_nil(@sales_month) and @sales_dumps != []) or
              (is_nil(@purchase_month) and @purchase_dumps != [])
          }
          class="space-y-block"
        >
          <Arrivals.source_record
            :if={is_nil(@sales_month)}
            can_sign_off={@can_sign_off}
            id="month-sales-sources"
            dumps={@sales_dumps}
            superseded_2b_ids={@superseded_2b_ids}
            client={@client}
            period={@period}
            open_period={@open_period}
            r1_signoff={@r1_signoff}
            gstr3b_signoff={@gstr3b_signoff}
          />
          <Arrivals.source_record
            :if={is_nil(@purchase_month)}
            can_sign_off={@can_sign_off}
            id="month-purchase-sources"
            dumps={@purchase_dumps}
            superseded_2b_ids={@superseded_2b_ids}
            client={@client}
            period={@period}
            open_period={@open_period}
            r1_signoff={@r1_signoff}
            gstr3b_signoff={@gstr3b_signoff}
          />
        </div>

        <main id="month-evidence" class="space-y-canvas min-w-0">
          <Sales.sales_section
            sales_month={@sales_month}
            client={@client}
            period={@period}
            invoices={@invoices}
            active_invoices={@active_invoices}
            open_issue_count={@open_issue_count}
            account={@sales_account}
            completeness={@sales_completeness}
            confirmation={@sales_confirmation}
            r1_signoff={@r1_signoff}
            month_issues={@month_issues}
            issues_by_invoice={@issues_by_invoice}
            pages_read={@sales_pages_read}
            visited={@visited_inums}
            reviewed_invoice={@last_reviewed_inum}
            derived={@derived_gstr1}
            diff={@gstr1_diff}
            accepted_diffs={@accepted_diffs}
            rippled={@rippled}
            ripple_seq={@ripple_seq}
            expanded_nodes={@expanded_nodes}
          >
            <:source>
              <Arrivals.source_record
                can_sign_off={@can_sign_off}
                id="month-sales-sources"
                dumps={@sales_dumps}
                superseded_2b_ids={@superseded_2b_ids}
                client={@client}
                period={@period}
                open_period={@open_period}
                r1_signoff={@r1_signoff}
                gstr3b_signoff={@gstr3b_signoff}
              />
            </:source>
            <:actions>
              <Filing.gstr1_actions
                sales_month={@sales_month}
                r1_signoff={@r1_signoff}
                open_issue_count={@open_issue_count}
                reviewable={@reviewable}
                completeness={@sales_completeness}
                can_sign_off={@can_sign_off}
                derived={@derived_gstr1}
              />
            </:actions>
          </Sales.sales_section>

          <Purchase.register
            purchase_month={@purchase_month}
            stats={@stats}
            document_flags={@document_flags}
            rows={@rows}
            client={@client}
            period={@period}
            gstr3b_signoff={@gstr3b_signoff}
            source_files={length(@active_purchase_dumps)}
            pages_read={@purchase_pages_read}
            itc={@itc}
          >
            <:assembled>
              <Filing.gstr3b_evidence
                gstr3b={@gstr3b}
                stats={@stats}
                signed={@gstr3b_signoff != nil}
              />
            </:assembled>
            <:source>
              <Arrivals.source_record
                can_sign_off={@can_sign_off}
                id="month-purchase-sources"
                dumps={@purchase_dumps}
                superseded_2b_ids={@superseded_2b_ids}
                client={@client}
                period={@period}
                open_period={@open_period}
                r1_signoff={@r1_signoff}
                gstr3b_signoff={@gstr3b_signoff}
              />
            </:source>
            <:actions>
              <Filing.gstr3b_actions
                purchase_month={@purchase_month}
                sales_month={@sales_month}
                stats={@stats}
                gstr3b_signoff={@gstr3b_signoff}
                r1_signoff={@r1_signoff}
                can_sign_off={@can_sign_off}
                sales_completeness={@sales_completeness}
                itc={@itc}
              />
            </:actions>
          </Purchase.register>
        </main>
      </div>

      <.live_component
        :if={(@live_action == :review and @purchase_review_route) && @purchase_month}
        module={PurchaseLive}
        id="purchase-review-live"
        month={@purchase_month}
        current_scope={@current_scope}
        route={@purchase_review_route}
        workings={@purchase_workings}
        signed_off={@gstr3b_signoff != nil}
      />

      <.live_component
        :if={(@live_action == :review and @sales_review_route) && @sales_month}
        module={SalesLive}
        id="sales-review-live"
        month={@sales_month}
        current_scope={@current_scope}
        route={@sales_review_route}
        workings={@sales_workings}
        decisions={@sales_decisions}
        signoff={@r1_signoff}
      />

      <Evidence.evidence_modals
        show_chase_history={@show_chase_history}
        client={@client}
        period={@period}
        asks={@asks}
        source_invoices={@invoices}
        duplicate_issue={@duplicate_issue}
        show_completeness_override={@show_completeness_override}
        completeness_override_form={@completeness_override_form}
      />
    </Layouts.app>
    """
  end
end
