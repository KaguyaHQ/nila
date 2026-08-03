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
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.{Account, Gstr1}
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias Nila.Gst.WorkQueue
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
    Workings
  }

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
      |> assign(:selected_row, nil)
      |> assign(:selected_inum, nil)
      |> assign(:last_reviewed_inum, nil)
      |> assign(:visited_inums, MapSet.new())
      |> assign(:expanded_nodes, MapSet.new())
      |> assign(:rippled, MapSet.new())
      |> assign(:ripple_seq, 0)
      |> assign(:correcting, nil)
      |> assign(:focused_issue, nil)
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
  def handle_params(params, _uri, socket) do
    inum = valid_invoice_number(socket.assigns.invoices, params["invoice"])

    {:noreply,
     assign(socket,
       selected_inum: inum,
       selected_row: nil,
       correcting: nil,
       last_reviewed_inum: inum || socket.assigns.last_reviewed_inum,
       visited_inums:
         if(inum,
           do: MapSet.put(socket.assigns.visited_inums, inum),
           else: socket.assigns.visited_inums
         )
     )}
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
    |> assign(:gstr2b_in, Enum.any?(dumps, &(&1.kind == "gstr2b" and &1.status == "extracted")))
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

  defp assign_purchase(socket, nil) do
    socket
    |> assign(:purchase_month, nil)
    |> assign(:gstr3b_signoff, nil)
    |> assign(:rows, [])
    |> assign(:stats, nil)
    |> assign(:document_flags, [])
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
    |> assign(:stats, Register.stats(summary))
    |> assign(:document_flags, summary["document_flags"] || [])
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

  defp assign_sales(socket, nil) do
    socket
    |> assign(:sales_month, nil)
    |> assign(:r1_signoff, nil)
    |> assign(:invoices, [])
    |> assign(:active_invoices, [])
    |> assign(:issues_by_invoice, %{})
    |> assign(:month_issues, [])
    |> assign(:flagged, MapSet.new())
    |> assign(:derived_gstr1, nil)
    |> assign(:gstr1_diff, nil)
    |> assign(:accepted_diffs, MapSet.new())
    |> assign(:sales_decisions, %{})
    |> assign(:sales_account, nil)
    |> assign(:sales_completeness, :open)
    |> assign(:sales_confirmation, nil)
    |> assign(:open_issue_count, 0)
    |> assign(:reviewable, false)
  end

  defp assign_sales(socket, sales) do
    signoff = fetch_or_nil(Signoffs.latest_gstr1_signoff(sales.id))

    workings =
      case signoff do
        nil when sales.invoices == [] ->
          %{
            source_invoices: [],
            active_invoices: [],
            printed_active_invoices: [],
            issues: [],
            flagged: MapSet.new(),
            derived: nil
          }

        nil ->
          SalesResolutions.workings(sales)

        signoff ->
          source = signoff.snapshot["invoices"]
          active = Enum.reject(source, &Map.has_key?(&1, "duplicate_copy"))

          %{
            source_invoices: source,
            active_invoices: active,
            printed_active_invoices: signoff.snapshot["printed_invoices"] || active,
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
    |> assign(:r1_signoff, signoff)
    |> assign(:invoices, invoices)
    |> assign(:active_invoices, active_invoices)
    |> assign(:issues_by_invoice, Enum.group_by(invoice_issues, & &1["source_id"]))
    |> assign(:month_issues, month_issues)
    |> assign(:flagged, flagged)
    |> assign(:derived_gstr1, derived)
    |> assign(:gstr1_diff, filed && derived && Gstr1Diff.rows(derived, filed))
    |> assign(:accepted_diffs, SalesResolutions.accepted_differences(sales))
    |> assign(:sales_decisions, SalesResolutions.latest_decisions(sales.id))
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

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select-row", %{"dom_id" => dom_id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1["dom_id"] == dom_id))
    {:noreply, assign(socket, selected_row: row, selected_inum: nil)}
  end

  # Opening an invoice marks its row read for this session only — a quiet
  # read/unread mark, never a persisted aggregate or a meter.
  def handle_event("select-invoice", %{"inum" => inum}, socket) do
    case valid_invoice_number(socket.assigns.invoices, inum) do
      nil ->
        {:noreply, socket}

      source_id ->
        {:noreply,
         socket
         |> assign(:focused_issue, nil)
         |> assign(:visited_inums, MapSet.put(socket.assigns.visited_inums, source_id))
         |> push_patch(to: month_path(socket, inum))}
    end
  end

  def handle_event(
        "review-sales-issue",
        %{"source" => source_id, "target" => target},
        socket
      ) do
    case valid_invoice_number(socket.assigns.invoices, source_id) do
      nil ->
        {:noreply, socket}

      source_id ->
        {:noreply,
         socket
         |> assign(:focused_issue, target)
         |> assign(:duplicate_review_target, nil)
         |> assign(:visited_inums, MapSet.put(socket.assigns.visited_inums, source_id))
         |> push_patch(to: month_path(socket, source_id))}
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

  def handle_event("navigate-invoice-review", %{"inum" => inum}, socket) do
    case valid_invoice_number(socket.assigns.invoices, inum) do
      nil -> {:noreply, socket}
      inum -> {:noreply, push_patch(socket, to: month_path(socket, inum), replace: true)}
    end
  end

  # Which workings buckets are open lives here rather than in an inline style,
  # so a re-render somewhere else on the page cannot collapse them.
  def handle_event("toggle-workings-node", %{"node" => node}, socket),
    do: {:noreply, update(socket, :expanded_nodes, &toggle(&1, node))}

  def handle_event("review-hsn-issue", %{"code" => code}, socket) do
    nodes = Workings.hsn_node_ids(socket.assigns.active_invoices, code)

    {:noreply,
     update(socket, :expanded_nodes, fn expanded ->
       MapSet.union(expanded, MapSet.new(nodes))
     end)}
  end

  def handle_event("close-evidence", _params, socket),
    do: {:noreply, assign(socket, selected_row: nil, correcting: nil)}

  def handle_event("close-invoice-review", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:focused_issue, nil)
       |> push_patch(to: month_path(socket), replace: true)}

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

  def handle_event(
        "resolve-invoice-issue",
        %{"target" => target, "decision" => "use_extracted_lines"},
        socket
      ) do
    issue =
      socket.assigns
      |> selected_invoice()
      |> then(fn invoice ->
        invoice && Helpers.invoice_issues(socket.assigns.issues_by_invoice, invoice)
      end)
      |> List.wrap()
      |> Enum.find(&(SalesWorkings.issue_key(&1) == target))

    if issue && not SalesWorkings.blocking?(issue) do
      record(socket, %{
        "verb" => "confirm_issue",
        "target" => target,
        "payload" => %{"decision" => "use_extracted_lines"}
      })
    else
      {:noreply, socket}
    end
  end

  def handle_event("resolve-invoice-issue", _params, socket), do: {:noreply, socket}

  def handle_event("undo", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "reopen", "target" => target})

  def handle_event("accept_difference", %{"target" => target}, socket),
    do: record(socket, %{"verb" => "accept_difference", "target" => target})

  def handle_event("start_correct", %{"field" => field}, socket) do
    invoice = selected_invoice(socket.assigns)

    {:noreply,
     assign(socket, :correcting, %{
       field: field,
       value: to_string(Gstr1.field_value(invoice, field))
     })}
  end

  def handle_event("cancel_correct", _params, socket),
    do: {:noreply, assign(socket, :correcting, nil)}

  def handle_event("save_correct", %{"field" => field, "value" => value}, socket) do
    invoice = selected_invoice(socket.assigns)
    from = Gstr1.field_value(invoice, field)
    value = String.trim(value)

    if value == "" or value == to_string(from) do
      {:noreply, assign(socket, :correcting, nil)}
    else
      record(socket, %{
        "verb" => "correct_field",
        "target" => invoice["id"] || invoice["pristine_inum"],
        "payload" => %{
          "field" => field,
          "from" => from,
          "to" => Gstr1.coerce_correction(field, value)
        }
      })
    end
  end

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
        {:noreply, socket |> reload() |> assign(:correcting, nil) |> ripple(old_derived)}

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

  defp selected_invoice(%{selected_inum: nil}), do: nil

  defp selected_invoice(assigns) do
    Enum.find(assigns.invoices, &(&1["id"] == assigns.selected_inum)) ||
      Enum.find(assigns.invoices, &(&1["invoice_number"] == assigns.selected_inum)) ||
      Enum.find(assigns.invoices, &(&1["pristine_inum"] == assigns.selected_inum))
  end

  defp review_navigation(_assigns, nil), do: %{previous: nil, next: nil}

  defp review_navigation(assigns, selected) do
    index =
      Enum.find_index(assigns.invoices, fn invoice ->
        invoice["id"] == selected["id"]
      end)

    previous =
      assigns.invoices
      |> Enum.take(index || 0)
      |> Enum.reverse()
      |> Enum.find(&invoice_unresolved?(assigns.issues_by_invoice, &1))

    next =
      assigns.invoices
      |> Enum.drop((index || -1) + 1)
      |> Enum.find(&invoice_unresolved?(assigns.issues_by_invoice, &1))

    %{
      previous: previous && invoice_identifier(assigns.invoices, previous),
      next: next && invoice_identifier(assigns.invoices, next)
    }
  end

  defp invoice_identifier(invoices, invoice) do
    if Enum.count(invoices, &(&1["invoice_number"] == invoice["invoice_number"])) == 1,
      do: invoice["invoice_number"],
      else: invoice["id"]
  end

  defp invoice_unresolved?(issues_by_invoice, invoice) do
    issues_by_invoice
    |> Helpers.invoice_issues(invoice)
    |> Enum.any?(&(&1["status"] == "open"))
  end

  defp month_path(socket, inum \\ nil) do
    %{client: client, period: period} = socket.assigns

    if inum,
      do: ~p"/gst/#{client.id}/#{period}?invoice=#{inum}",
      else: ~p"/gst/#{client.id}/#{period}"
  end

  @impl true
  def render(assigns) do
    selected_invoice = selected_invoice(assigns)

    duplicate_issue =
      Enum.find(assigns.month_issues, fn issue ->
        SalesWorkings.issue_key(issue) == assigns.duplicate_review_target
      end)

    assigns =
      assigns
      |> assign(:selected_invoice, selected_invoice)
      |> assign(:duplicate_issue, duplicate_issue)
      |> assign(:review_navigation, review_navigation(assigns, selected_invoice))

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
            source_files={length(@purchase_dumps)}
            pages_read={@purchase_pages_read}
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
              />
            </:actions>
          </Purchase.register>
        </main>
      </div>

      <Evidence.evidence_modals
        show_chase_history={@show_chase_history}
        client={@client}
        period={@period}
        asks={@asks}
        selected_row={@selected_row}
        selected_invoice={@selected_invoice}
        source_invoices={@invoices}
        duplicate_issue={@duplicate_issue}
        focused_issue={@focused_issue}
        show_completeness_override={@show_completeness_override}
        completeness_override_form={@completeness_override_form}
        issues_by_invoice={@issues_by_invoice}
        decisions={@sales_decisions}
        review_navigation={@review_navigation}
        r1_signoff={@r1_signoff}
        flagged={@flagged}
        correcting={@correcting}
        derived={@derived_gstr1}
      />
    </Layouts.app>
    """
  end
end
