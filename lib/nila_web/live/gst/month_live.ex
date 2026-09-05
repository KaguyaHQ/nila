defmodule NilaWeb.Gst.MonthLive do
  use NilaWeb, :live_view

  @moduledoc """
  The client-month workbench: the one room where a month gets closed.
  """

  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.{Calendar, Signoffs, WinmanGstr1}
  alias Nila.Gst.Intake.{DumpWorker, Dumps, Preconditions}
  alias Nila.Gst.Issues
  alias Nila.Gst.Purchase.{Groups, ItcCases, Reconciliation, Register, Resolutions, Review}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.{Account, Values}
  alias Nila.Gst.Sales.Review, as: SalesReview
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias Nila.Gst.WorkQueue
  alias Nila.TallyDevices
  alias Nila.TallyJobs
  alias Nila.Eval.Gstr1Diff

  alias NilaWeb.Components.Gst.Month.{
    Arrivals,
    Evidence,
    Filing,
    Helpers,
    Precondition,
    Purchase,
    Sales,
    Verdict,
    SalesWorkspace,
    Workings,
    Workpaper
  }

  alias NilaWeb.Components.Gst.Review.{PurchaseLive, SalesLive}
  alias NilaWeb.Gst.PeriodOptions

  @unsupported_sales_codes ~w(
    export_supply_unsupported sez_supply_unsupported nil_rated_supply_unsupported
    exempt_supply_unsupported non_gst_supply_unsupported outward_reverse_charge_unsupported
    cdnur_unsupported cancelled_document_unsupported amendment_document_unsupported cess_unsupported
  )

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
    if connected?(socket) do
      :ok = PurchaseMonths.subscribe(org_id)
      TallyJobs.subscribe_org(org_id)
    else
      :ok
    end
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

    if purchase || sales || dumps != [] || socket.assigns.live_action == :sales_workspace do
      socket
      |> assign(:client, client)
      |> assign(:period, period)
      |> assign(:page_title, "#{client.name} · #{period_label(period)}")
      |> assign(:purchase_review_route, nil)
      |> assign(:sales_review_route, nil)
      |> assign(:selected_track, :sales)
      |> assign(:sales_workspace_view, :overview)
      |> assign(:last_reviewed_inum, nil)
      |> assign(:visited_inums, MapSet.new())
      |> assign(:open_folds, MapSet.new())
      |> assign(:sales_register_query, "")
      |> assign(:sales_register_filter, :all)
      |> assign(:purchase_register_query, "")
      |> assign(:purchase_recon_filter, :all)
      |> assign(:purchase_action_filter, :all)
      |> assign(:purchase_register_sort, :register)
      |> assign(:sales_change, nil)
      |> assign(:expanded_nodes, MapSet.new())
      |> assign(:rippled, MapSet.new())
      |> assign(:ripple_seq, 0)
      |> assign(:duplicate_review_target, nil)
      |> assign(:show_chase_history, false)
      |> assign(:precondition_choice, nil)
      |> assign(:can_sign_off, Policy.can?(socket.assigns.current_scope, :sign_off))
      |> assign(:tally_companies, TallyDevices.list_open_companies(org_id, client.id))
      |> assign_month(purchase, sales)
    end
  end

  @impl true
  def handle_params(
        params,
        _uri,
        %{assigns: %{live_action: :sales_workspace}} = socket
      ) do
    {:noreply,
     assign(socket,
       purchase_review_route: nil,
       sales_review_route: nil,
       selected_track: :sales,
       sales_workspace_view: sales_workspace_view(params["view"])
     )}
  end

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
       sales_review_route: nil,
       selected_track: :purchases
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

    route =
      route
      |> Map.put(:focus, focus)
      |> Map.put(:return_to, valid_sales_review_return(params["return_to"]))
      |> Map.put(
        :tally_company_id,
        valid_sales_review_company(params["tally_company_id"], socket.assigns.tally_companies)
      )

    socket =
      assign(socket,
        purchase_review_route: nil,
        sales_review_route: route,
        selected_track: :sales,
        last_reviewed_inum: route.item || socket.assigns.last_reviewed_inum,
        visited_inums:
          if(route.item,
            do: MapSet.put(socket.assigns.visited_inums, route.item),
            else: socket.assigns.visited_inums
          )
      )

    workbench_path =
      if is_nil(socket.assigns.r1_signoff),
        do:
          NilaWeb.Gst.InvoiceWorkbench.path(
            socket.assigns.current_scope.current_org.id,
            socket.assigns.client.id,
            month.period,
            route.item,
            route.scope,
            route.return_to
          )

    if workbench_path do
      {:noreply, push_navigate(socket, to: workbench_path)}
    else
      if canonical_sales_route?(params, route) do
        {:noreply, socket}
      else
        {:noreply, push_patch(socket, to: sales_review_path(socket, route), replace: true)}
      end
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :review}} = socket) do
    track = fallback_track(socket.assigns)
    {:noreply, push_patch(socket, to: track_path(socket, track))}
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

  def handle_params(
        %{"track" => track} = params,
        _uri,
        %{assigns: %{live_action: :index}} = socket
      )
      when track in ["sales", "purchases", "gstr3b"] do
    legacy_month_params(params, socket)
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/gst/#{socket.assigns.client.id}/#{socket.assigns.period}/sales",
       replace: true
     )}
  end

  def handle_params(params, _uri, socket) do
    legacy_month_params(params, socket)
  end

  defp legacy_month_params(params, socket) do
    track = selected_track(params["track"], socket.assigns)

    socket =
      assign(socket,
        purchase_review_route: nil,
        sales_review_route: nil,
        selected_track: track
      )

    if is_nil(params["track"]) or params["track"] == Atom.to_string(track) do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: track_path(socket, track), replace: true)}
    end
  end

  defp valid_review_focus(nil, _focus), do: nil
  defp valid_review_focus(_item, nil), do: nil

  defp valid_review_focus(item, focus) do
    if Enum.any?(item.issues, &(SalesWorkings.issue_key(&1) == focus)), do: focus
  end

  defp canonical_sales_route?(params, route) do
    params["item"] == route.item and params["scope"] == to_string(route.scope) and
      params["focus"] == route.focus and params["return_to"] == route.return_to and
      params["tally_company_id"] == route.tally_company_id
  end

  defp valid_sales_review_return(return_to) when is_binary(return_to) do
    if return_to == "/sales-bills" or
         Regex.match?(~r|^/sales-bills/[^/?#]+/batch/[^/?#]+$|, return_to) or
         Regex.match?(~r|^/gst/\d+/\d{4}-\d{2}/sales(?:/[a-z0-9-]+)?$|, return_to),
       do: return_to
  end

  defp valid_sales_review_return(_return_to), do: nil

  defp valid_sales_review_company(company_id, companies) when is_binary(company_id) do
    if Enum.any?(companies, &(Integer.to_string(&1.id) == company_id)), do: company_id
  end

  defp valid_sales_review_company(_company_id, _companies), do: nil

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
      ", which this return cannot carry. Filing it as a regular invoice would be wrong, so it cannot be signed."
  end

  defp blocked_document("export_supply_unsupported"), do: "an export supply"
  defp blocked_document("sez_supply_unsupported"), do: "an SEZ supply"
  defp blocked_document("nil_rated_supply_unsupported"), do: "a nil-rated supply"
  defp blocked_document("exempt_supply_unsupported"), do: "an exempt supply"
  defp blocked_document("non_gst_supply_unsupported"), do: "a non-GST supply"
  defp blocked_document("outward_reverse_charge_unsupported"), do: "a reverse-charge supply"
  defp blocked_document("cdnur_unsupported"), do: "a note to an unregistered recipient"
  defp blocked_document("cancelled_document_unsupported"), do: "a cancelled document"
  defp blocked_document("amendment_document_unsupported"), do: "an amendment"
  defp blocked_document("cess_unsupported"), do: "a cess-bearing supply"
  defp blocked_document(code), do: code

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
    |> assign_review_projections()
    |> assign_gstr1_readiness()
    |> assign_gstr3b_readiness()
    |> assign_verdict(purchase, sales)
    |> assign_workpaper_states()
    |> assign_register_views()
  end

  defp assign_gstr1_readiness(socket) do
    assign(socket, :gstr1_readiness, Filing.gstr1_readiness(socket.assigns))
  end

  defp assign_gstr3b_readiness(socket) do
    assign(socket, :gstr3b_readiness, Filing.gstr3b_readiness(socket.assigns))
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
    |> assign(:sales_intake_open, Dumps.unresolved?(dumps, "sales"))
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
    |> assign(:purchase_review, nil)
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
          case_lines: ItcCases.restore_case_lines(snapshot["case_lines"] || []),
          document_cases: ItcCases.document_cases(snapshot["case_lines"] || []),
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

  defp signed_source_summary(invoices) do
    %{
      total: length(invoices),
      tally: Enum.count(invoices, &("tally" in List.wrap(&1["sources"]))),
      document: Enum.count(invoices, &("document" in List.wrap(&1["sources"]))),
      matched:
        Enum.count(invoices, &(Enum.sort(List.wrap(&1["sources"])) == ["document", "tally"])),
      missing_document: 0,
      missing_tally: 0,
      conflicts: 0,
      last_synced_at: nil
    }
  end

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
    |> assign(:open_issue_count, 0)
    |> assign(:reviewable, false)
    |> assign(:sales_review, nil)
    |> assign(:sales_source_summary, nil)
    |> assign(:gstr1_handoff, nil)
    |> assign(:tally_handoffs, [])
  end

  defp assign_sales(socket, sales, provided_workings) do
    signoff = fetch_or_nil(Signoffs.latest_gstr1_signoff(sales.id))

    workings =
      provided_workings ||
        case signoff do
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
              derived: signoff.snapshot["derived"],
              source_summary: signed_source_summary(source)
            }
        end

    source_invoices = workings.source_invoices
    active_invoices = workings.active_invoices
    issues = workings.issues
    flagged = workings.flagged
    derived = workings.derived

    pristine_by_id = Map.new(sales.invoices, &{&1["id"], &1})

    invoices =
      Enum.map(source_invoices, fn effective ->
        pristine = pristine_by_id[effective["id"]] || effective

        effective
        |> Map.put("pristine_inum", pristine["invoice_number"])
        |> Map.put("image_urls", sales_image_urls(effective, sales))
      end)

    {month_issues, invoice_issues} = Enum.split_with(issues, &is_nil(&1["source_id"]))
    org_id = sales.org_id

    account =
      Account.summarize(workings, %{
        files: length(Dumps.effective(org_id, sales.client_id, sales.period, "sales")),
        pages_read: socket.assigns.sales_pages_read
      })

    decisions = SalesResolutions.latest_decisions(sales.id)
    review = SalesReview.build(workings)
    filed = filed_gstr1(sales)

    socket
    |> assign(:sales_month, sales)
    |> assign(:sales_workings, workings)
    |> assign(:sales_decisions, decisions)
    |> assign(:sales_review, review)
    |> assign(:sales_source_summary, workings[:source_summary])
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
    |> assign(:open_issue_count, account.issues.required_count)
    |> assign(:reviewable, SalesWorkings.reviewable?(issues))
    |> assign(
      :gstr1_handoff,
      gstr1_handoff(invoices, issues, decisions, review, derived)
    )
    |> assign(:tally_handoffs, tally_handoffs(sales.org_id, signoff))
  end

  defp tally_handoffs(_org_id, nil), do: []

  defp tally_handoffs(org_id, signoff) do
    prefix = "gstr1:#{signoff.id}:company:"

    TallyJobs.list_by_source_prefix(org_id, prefix)
    |> Enum.group_by(fn job ->
      case Regex.run(~r/^gstr1:\d+:company:(\d+):voucher:/, job.source_key || "") do
        [_, company_id] -> String.to_integer(company_id)
        _ -> nil
      end
    end)
    |> Enum.reject(fn {company_id, _jobs} -> is_nil(company_id) end)
    |> Enum.map(fn {company_id, jobs} ->
      %{
        company_id: company_id,
        company_name:
          case Nila.Repo.get(Nila.TallyDevices.Company, company_id) do
            nil -> "Tally company"
            company -> company.name
          end,
        jobs: jobs,
        counts: Enum.frequencies_by(jobs, & &1.status)
      }
    end)
  end

  defp gstr1_handoff(invoices, issues, decisions, review, derived) do
    case WinmanGstr1.export_manifest(%{derived: derived, invoices: invoices}) do
      {:ok, export} ->
        actions = decisions |> Map.values() |> Enum.reject(&(&1.verb == "reopen"))

        unsupported_source_ids =
          issues
          |> Enum.filter(&(&1["code"] in @unsupported_sales_codes and &1["status"] == "open"))
          |> Enum.flat_map(fn issue ->
            List.wrap(issue["source_ids"] || issue["source_id"] || issue["invoice"])
          end)
          |> Enum.uniq()

        Map.merge(export, %{
          confirmations: Enum.count(actions, &(&1.verb == "confirm_issue")),
          corrections: Enum.count(actions, &(&1.verb == "correct_field")),
          review_cases_held: length(review.needs_you),
          blockers_held: Enum.count(issues, &(&1["status"] == "open" and Issues.gating?(&1))),
          unsupported_held: length(unsupported_source_ids)
        })

      {:error, :invalid_b2b_data} ->
        nil
    end
  end

  defp assign_review_projections(%{assigns: %{purchase_month: nil}} = socket), do: socket

  defp assign_review_projections(socket) do
    asked_at = socket.assigns.asks |> List.last() |> then(&(&1 && &1.inserted_at))

    assign(
      socket,
      :purchase_review,
      Review.project(socket.assigns.purchase_workings,
        month: socket.assigns.purchase_month,
        asked_at: asked_at
      )
    )
  end

  defp assign_register_views(socket) do
    sales_rows =
      filter_sales_rows(
        socket.assigns.invoices,
        socket.assigns.issues_by_invoice,
        socket.assigns.sales_register_query,
        socket.assigns.sales_register_filter
      )

    purchase_rows =
      filter_purchase_rows(
        socket.assigns.rows,
        socket.assigns.purchase_review,
        socket.assigns.purchase_register_query,
        socket.assigns.purchase_recon_filter,
        socket.assigns.purchase_action_filter,
        socket.assigns.purchase_register_sort
      )

    socket
    |> assign(:sales_register_rows, sales_rows)
    |> assign(:purchase_register_rows, purchase_rows)
    |> assign(
      :sales_register_form,
      to_form(%{"query" => socket.assigns.sales_register_query}, as: :sales_register)
    )
    |> assign(
      :purchase_register_form,
      to_form(%{"query" => socket.assigns.purchase_register_query}, as: :purchase_register)
    )
  end

  defp filter_sales_rows(rows, issues_by_invoice, query, filter) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    Enum.filter(rows, fn invoice ->
      issues =
        issues_by_invoice[invoice["id"]] || issues_by_invoice[invoice["invoice_number"]] || []

      review_case? =
        Enum.any?(issues, fn issue ->
          issue["status"] == "open" and
            Issues.resolution_kind(issue) in [:decision, :correction, :confirmation]
        end)

      filter_match? =
        case filter do
          :review_cases -> review_case?
          :no_open_checks -> not review_case?
          :all -> true
        end

      searchable =
        [invoice["invoice_number"], invoice["buyer_name"], invoice["buyer_gstin"]]
        |> Enum.join(" ")
        |> String.downcase()

      filter_match? and (query == "" or String.contains?(searchable, query))
    end)
  end

  defp filter_purchase_rows(rows, review, query, recon_filter, action_filter, sort) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    rows
    |> Enum.filter(fn row ->
      item = purchase_review_item(review, row)

      recon_match? =
        case recon_filter do
          :all -> true
          :resolved -> purchase_item_resolved?(item)
          bucket -> row["bucket"] == Atom.to_string(bucket)
        end

      action_match? = purchase_action_match?(action_filter, item)

      searchable =
        [row["invoice_number"], row["vendor_name"], row["vendor_gstin"]]
        |> Enum.join(" ")
        |> String.downcase()

      recon_match? and action_match? and
        (query == "" or String.contains?(searchable, query))
    end)
    |> sort_purchase_rows(sort)
  end

  defp purchase_review_item(nil, _row), do: nil
  defp purchase_review_item(review, row), do: Review.lookup(review.all, row["review_item"])

  defp purchase_item_resolved?(%{resolved: true}), do: true
  defp purchase_item_resolved?(_item), do: false

  defp purchase_action_match?(:all, _item), do: true

  defp purchase_action_match?(:decisions, %{resolved: false, kind: kind}) when kind != :gstr2b,
    do: true

  defp purchase_action_match?(:documents, %{resolved: false, kind: :gstr2b, asked_at: nil}),
    do: true

  defp purchase_action_match?(:waiting, %{resolved: false, kind: :gstr2b, asked_at: asked_at}),
    do: not is_nil(asked_at)

  defp purchase_action_match?(:resolved, %{resolved: true}), do: true
  defp purchase_action_match?(_filter, _item), do: false

  defp sort_purchase_rows(rows, :materiality),
    do: Enum.sort_by(rows, &abs(&1["itc_effect_paise"] || 0), :desc)

  defp sort_purchase_rows(rows, :vendor),
    do:
      Enum.sort_by(rows, &{String.downcase(&1["vendor_name"] || ""), &1["invoice_number"] || ""})

  defp sort_purchase_rows(rows, :register), do: rows

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

  defp assign_workpaper_states(socket) do
    sales = sales_workpaper_state(socket.assigns.gstr1_readiness)
    purchase_state = purchase_track_state(socket.assigns)
    purchase = purchase_workpaper_state(purchase_state)

    socket
    |> assign(:purchase_track_state, purchase_state)
    |> assign(:workpaper_states, %{
      sales: sales,
      purchases: purchase,
      gstr3b: socket.assigns.gstr3b_readiness
    })
    |> assign(:global_verdict, without_track_door(socket.assigns.verdict))
  end

  defp sales_workpaper_state(%{state: :absent}),
    do: %{label: "Documents not in", variant: "neutral"}

  defp sales_workpaper_state(%{state: :provisional}),
    do: %{label: "Needs review", variant: "warning"}

  defp sales_workpaper_state(%{state: :ready}),
    do: %{label: "Ready for approval", variant: "success"}

  defp sales_workpaper_state(%{state: :awaiting_senior}),
    do: %{label: "Awaiting senior", variant: "info"}

  defp sales_workpaper_state(%{state: :approved}),
    do: %{label: "Approved", variant: "success"}

  defp sales_workpaper_state(%{state: :filed}),
    do: %{label: "Filed", variant: "neutral"}

  defp purchase_track_state(%{tracks: %{purchase: state}})
       when state in [:absent, :awaiting_2b, :need_2b, :signed, :filed],
       do: state

  defp purchase_track_state(%{stats: %{need_decision: count}}) when count > 0, do: :open

  defp purchase_track_state(%{stats: %{awaiting_bills: count}}) when count > 0,
    do: :awaiting_bills

  defp purchase_track_state(%{stats: %{value_disputes: count}}) when count > 0,
    do: :differences

  defp purchase_track_state(%{tracks: %{purchase: state}}), do: state

  defp purchase_workpaper_state(:absent),
    do: %{label: "Documents not in", variant: "neutral"}

  defp purchase_workpaper_state(:awaiting_2b),
    do: %{label: "Waiting for GSTR-2B", variant: "info"}

  defp purchase_workpaper_state(:need_2b),
    do: %{label: "GSTR-2B not in", variant: "warning"}

  defp purchase_workpaper_state(:open),
    do: %{label: "Needs review", variant: "warning"}

  defp purchase_workpaper_state(:awaiting_bills),
    do: %{label: "Waiting on documents", variant: "info"}

  defp purchase_workpaper_state(:differences),
    do: %{label: "Differences noted", variant: "info"}

  defp purchase_workpaper_state(:signed),
    do: %{label: "Position frozen", variant: "info"}

  defp purchase_workpaper_state(:filed),
    do: %{label: "Filed", variant: "neutral"}

  defp purchase_workpaper_state(_state),
    do: %{label: "Reconciled", variant: "success"}

  defp without_track_door(%{door: %{id: id}} = verdict)
       when id in ~w(month-door-file-sales month-door-file-purchase month-door-bring-sales month-door-bring-purchase month-door-bring-2b),
       do: %{verdict | door: nil}

  defp without_track_door(verdict), do: verdict

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
        gstr3b_filed: purchase != nil and purchase.filed_at != nil
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
      |> assign_review_projections()
      |> assign_verdict(month, socket.assigns.sales_month)
      |> assign_gstr3b_readiness()
      |> assign_workpaper_states()
      |> assign_register_views()

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
    old_review = socket.assigns.sales_review

    socket =
      socket
      |> assign_sales(month, workings)
      |> assign_review_projections()
      |> assign_gstr1_readiness()
      |> assign_verdict(socket.assigns.purchase_month, month)
      |> assign_gstr3b_readiness()
      |> assign_workpaper_states()
      |> assign_register_views()
      |> assign(
        :sales_change,
        sales_change(requested[:action], old_derived, workings.derived, old_review)
      )
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

  def handle_info(:tally_jobs_changed, socket) do
    org_id = socket.assigns.current_scope.current_org.id
    {:noreply, assign(socket, :tally_handoffs, tally_handoffs(org_id, socket.assigns.r1_signoff))}
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

  def handle_event("toggle-fold", %{"fold" => fold}, socket),
    do: {:noreply, update(socket, :open_folds, &toggle(&1, fold))}

  def handle_event("dismiss-sales-change", _params, socket),
    do: {:noreply, assign(socket, :sales_change, nil)}

  def handle_event("search-sales-register", %{"sales_register" => params}, socket) do
    {:noreply,
     socket
     |> assign(:sales_register_query, params["query"] || "")
     |> assign_register_views()}
  end

  def handle_event("filter-sales-register", %{"filter" => filter}, socket)
      when filter in ~w(review_cases no_open_checks all) do
    {:noreply,
     socket
     |> assign(:sales_register_filter, String.to_existing_atom(filter))
     |> assign_register_views()}
  end

  def handle_event("search-purchase-register", %{"purchase_register" => params}, socket) do
    {:noreply,
     socket
     |> assign(:purchase_register_query, params["query"] || "")
     |> assign_register_views()}
  end

  def handle_event("filter-purchase-reconciliation", %{"filter" => filter}, socket)
      when filter in ~w(all matched needs_human value_mismatch in_books_not_2b in_2b_not_books resolved) do
    {:noreply,
     socket
     |> assign(:purchase_recon_filter, String.to_existing_atom(filter))
     |> assign_register_views()}
  end

  def handle_event("filter-purchase-action", %{"filter" => filter}, socket)
      when filter in ~w(all decisions documents waiting resolved) do
    {:noreply,
     socket
     |> assign(:purchase_action_filter, String.to_existing_atom(filter))
     |> assign_register_views()}
  end

  def handle_event("sort-purchase-register", %{"sort" => sort}, socket)
      when sort in ~w(register materiality vendor) do
    {:noreply,
     socket
     |> assign(:purchase_register_sort, String.to_existing_atom(sort))
     |> assign_register_views()}
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
     socket
     |> update(:expanded_nodes, fn expanded -> MapSet.union(expanded, MapSet.new(nodes)) end)
     |> update(:open_folds, &MapSet.put(&1, "gstr1-control-hsn"))}
  end

  def handle_event("open-chase-history", _params, socket),
    do: {:noreply, assign(socket, :show_chase_history, true)}

  def handle_event("close-chase-history", _params, socket),
    do: {:noreply, assign(socket, :show_chase_history, false)}

  def handle_event("confirm_issue", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "confirm_issue", "target" => target})

  def handle_event("undo", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "reopen", "target" => target})

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

      {:error, :unresolved_sales_intake} ->
        {:noreply, put_flash(socket, :error, "A supplied sales packet is still unresolved.")}

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

      {:error, {:ambiguous_itc_cases, _case_ids}} ->
        {:noreply,
         put_flash(socket, :error, "Resolve the ambiguous invoice identities before signing.")}

      {:error, {:itc_already_allocated, _case_ids}} ->
        {:noreply,
         put_flash(socket, :error, "This ITC was already reserved or claimed in another period.")}

      {:error, :unresolved_sales_intake} ->
        {:noreply, put_flash(socket, :error, "A supplied sales packet is still unresolved.")}
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

  # Senior-only because abandoning unresolved intake is a deliberate audit
  # decision, even though the failed packet produced no rows.
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

  defp answer_precondition(socket, dump, %{"answer" => "move", "period" => period}, user_id) do
    case Preconditions.move(dump, period, user_id) do
      {:ok, moved} ->
        {:ok, _job} = Oban.insert(DumpWorker.new(%{dump_id: moved.id}))

        {:noreply,
         socket
         |> put_flash(:info, "Packet moved to #{period_label(period)}.")
         |> push_navigate(to: moved_work_path(moved))}

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

  defp record(socket, attrs) do
    case SalesResolutions.record(
           socket.assigns.sales_month,
           attrs,
           socket.assigns.current_scope.user.id
         ) do
      {:ok, _} ->
        old_derived = socket.assigns.derived_gstr1
        old_review = socket.assigns.sales_review
        socket = reload(socket)

        {:noreply,
         socket
         |> assign(
           :sales_change,
           sales_change(attrs, old_derived, socket.assigns.derived_gstr1, old_review)
         )
         |> ripple(old_derived)}

      {:error, :signed_off} ->
        {:noreply,
         put_flash(socket, :error, "This GSTR-1 is signed off — a senior must reopen it first.")}
    end
  end

  defp sales_change(nil, _old_derived, _new_derived, _review), do: nil

  defp sales_change(action, old_derived, new_derived, review) do
    before = old_derived && Values.filed_totals(old_derived)
    after_totals = new_derived && Values.filed_totals(new_derived)
    verb = action[:verb] || action["verb"]
    payload = action[:payload] || action["payload"] || %{}
    field = payload[:field] || payload["field"]

    context = sales_action_context(action, review)

    title =
      case {verb, field, context} do
        {"correct_field", field, context} when is_binary(field) and is_binary(context) ->
          "Correction · #{context} · #{humanize_field_path(field)}"

        {"correct_field", field, _context} when is_binary(field) ->
          "Correction · #{humanize_field_path(field)}"

        {"correct_field", _field, context} when is_binary(context) ->
          "Correction · #{context}"

        {"correct_field", _field, _context} ->
          "Invoice correction recorded"

        {"confirm_issue", _field, context} when is_binary(context) ->
          "Confirmation · #{context}"

        {"confirm_issue", _field, _context} ->
          "Confirmation recorded"

        {"exclude_duplicate_copy", _field, context} when is_binary(context) ->
          "Duplicate excluded · #{context}"

        {"exclude_duplicate_copy", _field, _context} ->
          "Duplicate copy excluded"

        _other ->
          "Review recorded"
      end

    body =
      cond do
        is_nil(before) or is_nil(after_totals) ->
          "The effective sales register was reworked."

        before == after_totals ->
          "Proposed GSTR-1 totals did not change."

        true ->
          "Proposed GSTR-1 changed from #{Helpers.rupees(before.taxable)} taxable and #{Helpers.rupees(before.tax)} tax to #{Helpers.rupees(after_totals.taxable)} taxable and #{Helpers.rupees(after_totals.tax)} tax."
      end

    %{title: title, body: body}
  end

  defp humanize_field_path(field) do
    field
    |> String.replace("_", " ")
    |> String.replace(".", " ")
    |> String.capitalize()
  end

  defp sales_action_context(action, review) do
    target = action[:target] || action["target"]
    payload = action[:payload] || action["payload"] || %{}

    source_id =
      cond do
        Enum.any?(review.all, &(&1.source_id == target)) ->
          target

        item = Enum.find(review.all, &(target in &1.actionable_targets)) ->
          item.source_id

        is_binary(payload["excluded_source_id"]) ->
          payload["excluded_source_id"]

        true ->
          nil
      end

    case Enum.find(review.all, &(&1.source_id == source_id)) do
      nil -> if(is_binary(target), do: "target #{target}")
      item -> "invoice #{item.invoice["invoice_number"] || item.source_id}"
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

  defp month_base_path(socket) do
    %{client: client, period: period} = socket.assigns
    ~p"/gst/#{client.id}/#{period}"
  end

  defp moved_work_path(%{kind: kind, client_id: client_id, period: period})
       when kind in ~w(purchase gstr2b),
       do: ~p"/gst/#{client_id}/#{period}?track=purchases"

  defp moved_work_path(%{client_id: client_id, period: period}),
    do: ~p"/gst/#{client_id}/#{period}/sales/uploads"

  defp track_path(socket, track),
    do: month_base_path(socket) <> "?" <> URI.encode_query(%{"track" => to_string(track)})

  defp purchase_review_path(socket, route) do
    params = %{"item" => route.item, "scope" => to_string(route.scope)}
    month_base_path(socket) <> "/review/purchase?" <> URI.encode_query(params)
  end

  defp sales_review_path(socket, route) do
    params =
      %{
        "item" => route.item,
        "scope" => to_string(route.scope),
        "focus" => route[:focus],
        "tally_company_id" => route[:tally_company_id],
        "return_to" => route[:return_to]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    month_base_path(socket) <> "/review/sales?" <> URI.encode_query(params)
  end

  defp selected_track("sales", _assigns), do: :sales
  defp selected_track("purchases", _assigns), do: :purchases
  defp selected_track("gstr3b", _assigns), do: :gstr3b
  defp selected_track(_track, assigns), do: fallback_track(assigns)

  defp fallback_track(%{sales_month: sales}) when not is_nil(sales), do: :sales
  defp fallback_track(%{purchase_month: purchase}) when not is_nil(purchase), do: :purchases
  defp fallback_track(%{sales_dumps: [_ | _]}), do: :sales
  defp fallback_track(_assigns), do: :purchases

  defp sales_workspace_view(nil), do: :overview
  defp sales_workspace_view("invoices"), do: :invoices
  defp sales_workspace_view("uploads"), do: :uploads
  defp sales_workspace_view("b2b"), do: :b2b
  defp sales_workspace_view("b2cl"), do: :b2cl
  defp sales_workspace_view("b2cs"), do: :b2cs
  defp sales_workspace_view("cdnr"), do: :cdnr
  defp sales_workspace_view("hsn"), do: :hsn
  defp sales_workspace_view("documents"), do: :documents
  defp sales_workspace_view(_view), do: :overview

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
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active_client={@client}
    >
      <SalesWorkspace.workspace
        :if={@live_action == :sales_workspace}
        client={@client}
        period={@period}
        view={@sales_workspace_view}
        invoices={@invoices}
        active_invoices={@active_invoices}
        register_rows={@sales_register_rows}
        register_form={@sales_register_form}
        register_filter={@sales_register_filter}
        issues_by_invoice={@issues_by_invoice}
        review={
          @sales_review || %{needs_you: [], all: [], progress: %{completed: 0, open: 0, total: 0}}
        }
        derived={@derived_gstr1}
        readiness={@gstr1_readiness}
        dumps={@sales_dumps}
        expanded_nodes={@expanded_nodes}
        rippled={@rippled}
        ripple_seq={@ripple_seq}
      >
        <:source>
          <Arrivals.source_record
            can_sign_off={@can_sign_off}
            id="sales-period-source-record"
            dumps={@sales_dumps}
            superseded_2b_ids={@superseded_2b_ids}
            client={@client}
            period={@period}
            open_period={@open_period}
            r1_signoff={@r1_signoff}
            gstr3b_signoff={@gstr3b_signoff}
          />
        </:source>
      </SalesWorkspace.workspace>
      <div
        :if={@live_action != :sales_workspace}
        id="month-page"
        class="space-y-region mx-auto max-w-7xl"
      >
        <Verdict.verdict
          verdict={@global_verdict}
          period={@period}
        />
        <Precondition.question
          :if={@verdict[:question]}
          dump={@verdict.question.dump}
          finding={@verdict.question.finding}
          period={@period}
          choice={@precondition_choice}
          period_options={@move_options || []}
        /> <Arrivals.chase_history_link asks={@asks} />
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

        <Workpaper.tabs
          client={@client}
          period={@period}
          selected={@selected_track}
          states={@workpaper_states}
        />
        <main id="month-evidence" class="space-y-canvas min-w-0">
          <%= case @selected_track do %>
            <% :sales -> %>
              <%= if @sales_month do %>
                <Sales.sales_section
                  sales_month={@sales_month}
                  client={@client}
                  period={@period}
                  invoices={@invoices}
                  active_invoices={@active_invoices}
                  open_issue_count={@open_issue_count}
                  account={@sales_account}
                  r1_signoff={@r1_signoff}
                  readiness={@gstr1_readiness}
                  issues_by_invoice={@issues_by_invoice}
                  pages_read={@sales_pages_read}
                  visited={@visited_inums}
                  open_folds={@open_folds}
                  register_rows={@sales_register_rows}
                  register_form={@sales_register_form}
                  register_filter={@sales_register_filter}
                  review={@sales_review}
                  source_summary={@sales_source_summary}
                  decisions={@sales_decisions}
                  change={@sales_change}
                  reviewed_invoice={@last_reviewed_inum}
                  derived={@derived_gstr1}
                  diff={@gstr1_diff}
                  accepted_diffs={@accepted_diffs}
                  rippled={@rippled}
                  ripple_seq={@ripple_seq}
                  expanded_nodes={@expanded_nodes}
                >
                  <:primary_action>
                    <Filing.gstr1_primary_action
                      sales_month={@sales_month}
                      r1_signoff={@r1_signoff}
                      open_issue_count={@open_issue_count}
                      reviewable={@reviewable}
                      sales_intake_open={@sales_intake_open}
                      can_sign_off={@can_sign_off}
                      derived={@derived_gstr1}
                      readiness={@gstr1_readiness}
                      review_case_count={length(@sales_review.needs_you)}
                    />
                  </:primary_action>

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
                      sales_intake_open={@sales_intake_open}
                      can_sign_off={@can_sign_off}
                      derived={@derived_gstr1}
                      readiness={@gstr1_readiness}
                      handoff={@gstr1_handoff}
                      tally_companies={@tally_companies}
                      tally_handoffs={@tally_handoffs}
                    />
                  </:actions>
                </Sales.sales_section>
              <% else %>
                <Workpaper.empty_state
                  track={:sales}
                  client={@client}
                  period={@period}
                  purchase_present={not is_nil(@purchase_month)}
                  show_action={is_nil(@verdict[:question])}
                />
              <% end %>
            <% :purchases -> %>
              <%= if @purchase_month do %>
                <Purchase.register
                  purchase_month={@purchase_month}
                  stats={@stats}
                  document_flags={@document_flags}
                  rows={@rows}
                  client={@client}
                  period={@period}
                  gstr3b_signoff={@gstr3b_signoff}
                  itc={@itc}
                  case_lines={(@purchase_workings && @purchase_workings.case_lines) || []}
                  track_state={@purchase_track_state}
                  review={@purchase_review}
                  open_folds={@open_folds}
                  visible_rows={@purchase_register_rows}
                  register_form={@purchase_register_form}
                  recon_filter={@purchase_recon_filter}
                  action_filter={@purchase_action_filter}
                  register_sort={@purchase_register_sort}
                  gstr2b_in={@gstr2b_in}
                  asks={@asks}
                >
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
                </Purchase.register>
              <% else %>
                <Workpaper.empty_state
                  track={:purchases}
                  client={@client}
                  period={@period}
                  purchase_present={false}
                  show_action={is_nil(@verdict[:question])}
                />
              <% end %>
            <% :gstr3b -> %>
              <%= if @purchase_month do %>
                <section id="month-gstr3b-workpaper" class="space-y-section">
                  <Filing.gstr3b_evidence
                    gstr3b={@gstr3b}
                    itc={@itc}
                    stats={@stats}
                    signed={@gstr3b_signoff != nil}
                  >
                    <:primary_action>
                      <Filing.gstr3b_primary_action
                        purchase_month={@purchase_month}
                        sales_month={@sales_month}
                        stats={@stats}
                        gstr3b_signoff={@gstr3b_signoff}
                        r1_signoff={@r1_signoff}
                        can_sign_off={@can_sign_off}
                        sales_intake_open={@sales_intake_open}
                        itc={@itc}
                        gstr3b={@gstr3b}
                      />
                    </:primary_action>
                  </Filing.gstr3b_evidence>

                  <Filing.gstr3b_blocker_list
                    purchase_month={@purchase_month}
                    sales_month={@sales_month}
                    stats={@stats}
                    gstr3b_signoff={@gstr3b_signoff}
                    r1_signoff={@r1_signoff}
                    can_sign_off={@can_sign_off}
                    sales_intake_open={@sales_intake_open}
                    itc={@itc}
                    gstr3b={@gstr3b}
                  />
                  <Workpaper.section_nav links={
                    [
                      %{id: "month-3b", label: "Return position"},
                      @gstr3b_readiness.state == :blocked &&
                        %{id: "gstr3b-blockers", label: "Blockers"},
                      %{id: "gstr3b-controls", label: "Controls"},
                      %{id: "gstr3b-source-references", label: "Sources"},
                      @gstr3b_readiness.state != :blocked &&
                        %{id: "month-exit-gstr3b", label: "Sign-off"}
                    ]
                    |> Enum.filter(&is_map/1)
                  } />
                  <Filing.gstr3b_controls
                    gstr3b={@gstr3b}
                    itc={@itc}
                    stats={@stats}
                    signed={@gstr3b_signoff != nil}
                    open_folds={@open_folds}
                    r1_signoff={@r1_signoff}
                    gstr3b_signoff={@gstr3b_signoff}
                    client_id={@client.id}
                    period={@period}
                  />
                  <Filing.gstr3b_actions
                    purchase_month={@purchase_month}
                    sales_month={@sales_month}
                    stats={@stats}
                    gstr3b_signoff={@gstr3b_signoff}
                    r1_signoff={@r1_signoff}
                    can_sign_off={@can_sign_off}
                    sales_intake_open={@sales_intake_open}
                    itc={@itc}
                    gstr3b={@gstr3b}
                  />
                </section>
              <% else %>
                <Workpaper.empty_state
                  track={:gstr3b}
                  client={@client}
                  period={@period}
                  purchase_present={false}
                  show_action={is_nil(@verdict[:question])}
                />
              <% end %>
          <% end %>
        </main>
      </div>

      <.live_component
        :if={(@live_action == :review and @purchase_review_route) && @purchase_month}
        module={PurchaseLive}
        id="purchase-review-live"
        month={@purchase_month}
        client={@client}
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
        tally_company={sales_review_company(@tally_companies, @sales_review_route)}
      />
      <Evidence.evidence_modals
        show_chase_history={@show_chase_history}
        client={@client}
        period={@period}
        asks={@asks}
        source_invoices={@invoices}
        duplicate_issue={@duplicate_issue}
      />
    </Layouts.app>
    """
  end

  defp sales_review_company(companies, route) do
    case route[:tally_company_id] do
      company_id when is_binary(company_id) ->
        Enum.find(companies, &(Integer.to_string(&1.id) == company_id))

      _missing ->
        List.first(companies)
    end
  end
end
