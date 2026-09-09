defmodule NilaWeb.Gst.SalesBillReview do
  @moduledoc "Shared invoice editing, batch loading, and Tally posting state for sales surfaces."
  use NilaWeb, :html
  import Phoenix.LiveView

  alias Nila.Clients
  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Money
  alias Nila.Gst.Purchase.Months, as: ClientMonths

  alias Nila.Gst.Sales.{
    Batch,
    Gstr1,
    Invoice,
    InvoiceCorrections,
    InvoiceRemovals,
    TallyPacket
  }

  alias Nila.{TallyDevices, TallyJobs, TallyMappings}
  alias NilaWeb.Gst.SalesIssuePresentation
  alias NilaWeb.Gst.InvoiceWorkbench
  alias NilaWeb.Presence

  def mount(%{"client_id" => client_id, "batch_ref" => batch_ref}, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    if connected?(socket) and not Map.has_key?(socket.assigns, :sales_batch),
      do: ClientMonths.subscribe(org_id)

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, batch, dumps} <- TallyPacket.fetch_with_record(org_id, client_id, batch_ref) do
      if connected?(socket) and not Map.has_key?(socket.assigns, :sales_batch) do
        TallyJobs.subscribe_org(org_id)
        Phoenix.PubSub.subscribe(Nila.PubSub, tally_presence_topic(org_id))
      end

      company = tally_destination(org_id, client.id, batch)
      tally_masters = tally_masters(org_id, company)
      source_prefix = Batch.source_prefix(batch)
      packet = prepare_packet(dumps, client.id)
      tally_jobs = list_tally_jobs(org_id, batch)

      socket =
        socket
        |> assign(:page_title, "Sales bills")
        |> assign(:client, client)
        |> assign(:sales_batch, batch)
        |> assign(:batch_ref, batch_ref)
        |> assign(:packet, packet)
        |> assign(:source_dumps, dumps)
        |> assign(:workbench_context, nil)
        |> assign(:workbench_period, nil)
        |> assign(:workbench_scope, "all")
        |> assign(:workbench_return_to, nil)
        |> assign(:accounting_view?, false)
        |> assign(:invoice_queue_open?, false)
        |> assign(:processing_jobs, processing_jobs(dumps))
        |> assign(:tally_company, company)
        |> assign(:tally_masters, tally_masters)
        |> assign(:tally_masters_available?, tally_masters != [])
        |> assign(:tally_masters_synced_at, latest_master_sync(tally_masters))
        |> assign_tally_availability(org_id, company)
        |> assign(:tally_source_prefix, source_prefix)
        |> assign(:tally_jobs, tally_jobs)
        |> assign(:selected_invoice, nil)
        |> assign(:posting_preview_invoice, nil)
        |> assign(:tally_posting, nil)
        |> assign(:ledger_picker, empty_ledger_picker())
        |> assign(:required_mapping_invoices, [])
        |> assign(:required_mapping_counts, %{})
        |> assign(:review_mode?, false)
        |> assign(:posting_navigation, %{previous: nil, next: nil, position: 0, total: 0})
        |> assign(:evidence_open, false)
        |> assign(:evidence_page, 0)
        |> assign(:editing_line_index, nil)
        |> assign(:editing_invoice_facts?, false)
        |> assign(:invoice_facts_form, nil)
        |> assign(:invoice_facts_focus, nil)
        |> assign(:invoice_facts_section, "details")
        |> assign(:invoice_facts_return_focus, nil)
        |> assign(:invoice_facts_error, nil)
        |> assign(:editing_narration?, false)
        |> assign(:line_edit_row, nil)
        |> assign(:line_edit_form, nil)
        |> assign(:line_edit_error, nil)
        |> assign(:confirming_tally_send, false)
        |> assign(:send_holds, current_send_holds(org_id, company, packet))
        |> assign(:send_error, nil)
        |> refresh_required_mapping_invoices()

      {:ok, socket}
    else
      _not_found ->
        {:ok,
         socket
         |> put_flash(:error, "That sales packet could not be found.")
         |> push_navigate(to: ~p"/sales-bills")}
    end
  end

  def handle_params(params, _uri, socket) do
    previous_id = invoice_id(socket.assigns.selected_invoice)
    review_mode? = params["review"] == "required"
    accounting_view? = params["view"] == "accounting" && not is_nil(socket.assigns.tally_company)
    socket = assign(socket, :accounting_view?, accounting_view?)

    invoice =
      case params["item"] do
        nil ->
          nil

        source_id ->
          Enum.find(
            socket.assigns.packet.all_invoices,
            &((&1["id"] || &1["invoice_number"]) == source_id)
          )
      end

    selected_review = if accounting_view?, do: selected_review(socket.assigns.packet, invoice)

    navigation_invoices =
      if review_mode?,
        do: attention_invoices(socket.assigns.packet, socket.assigns.required_mapping_invoices),
        else: socket.assigns.packet.all_invoices

    {:noreply,
     socket
     |> assign(:review_mode?, review_mode?)
     |> assign(:selected_invoice, invoice)
     |> assign(:selected_review, selected_review)
     |> assign(:posting_preview_invoice, invoice)
     |> assign(:tally_posting, tally_posting(socket.assigns, invoice))
     |> assign(
       :ledger_picker,
       empty_ledger_picker(socket.assigns.ledger_picker.generation + 1)
     )
     |> assign(
       :posting_navigation,
       posting_navigation(navigation_invoices, invoice)
     )
     |> assign(
       :editing_line_index,
       if(previous_id == invoice_id(invoice), do: socket.assigns.editing_line_index, else: nil)
     )
     |> assign(
       :editing_invoice_facts?,
       previous_id == invoice_id(invoice) && socket.assigns.editing_invoice_facts?
     )
     |> assign(
       :invoice_facts_form,
       if(previous_id == invoice_id(invoice), do: socket.assigns.invoice_facts_form, else: nil)
     )
     |> assign(
       :invoice_facts_focus,
       if(previous_id == invoice_id(invoice), do: socket.assigns.invoice_facts_focus, else: nil)
     )
     |> assign(
       :invoice_facts_return_focus,
       if(previous_id == invoice_id(invoice),
         do: socket.assigns.invoice_facts_return_focus,
         else: nil
       )
     )
     |> assign(
       :invoice_facts_error,
       if(previous_id == invoice_id(invoice), do: socket.assigns.invoice_facts_error, else: nil)
     )
     |> assign(
       :editing_narration?,
       previous_id == invoice_id(invoice) && socket.assigns.editing_narration?
     )
     |> assign(
       :line_edit_row,
       if(previous_id == invoice_id(invoice), do: socket.assigns.line_edit_row, else: nil)
     )
     |> assign(
       :line_edit_form,
       if(previous_id == invoice_id(invoice), do: socket.assigns.line_edit_form, else: nil)
     )
     |> assign(:line_edit_error, nil)
     |> assign(:evidence_open, previous_id == invoice_id(invoice) && socket.assigns.evidence_open)
     |> assign(
       :evidence_page,
       if(previous_id == invoice_id(invoice), do: socket.assigns.evidence_page, else: 0)
     )
     |> assign(:workbench_period, params["period"])
     |> assign(:workbench_scope, params["scope"] || "all")
     |> assign(:workbench_return_to, params["return_to"])
     |> refresh_workbench()}
  end

  defp refresh_workbench(socket) do
    invoice = socket.assigns.selected_invoice
    source_id = invoice_id(invoice)

    period =
      socket.assigns.workbench_period ||
        Enum.find_value(socket.assigns.source_dumps, fn dump ->
          if Enum.any?(dump.invoices || [], &(Invoice.source_id(&1) == source_id)),
            do: dump.period
        end)

    context =
      if period && invoice do
        case InvoiceWorkbench.load(
               socket.assigns.current_scope.current_org.id,
               socket.assigns.client.id,
               period,
               source_id,
               socket.assigns.workbench_scope
             ) do
          {:ok, %{item: item} = context} when not is_nil(item) -> context
          _ -> nil
        end
      end

    context =
      if context && socket.assigns[:review_batch] do
        source_ids = MapSet.new(socket.assigns.packet.all_invoices, &invoice_id/1)
        all = Enum.filter(context.review.all, &MapSet.member?(source_ids, &1.source_id))

        needs_you =
          if socket.assigns.accounting_view? do
            attention_ids =
              socket.assigns.packet
              |> attention_invoices(socket.assigns.required_mapping_invoices)
              |> MapSet.new(&invoice_id/1)

            Enum.filter(all, &MapSet.member?(attention_ids, &1.source_id))
          else
            Enum.filter(context.review.needs_you, &MapSet.member?(source_ids, &1.source_id))
          end

        review = %{context.review | all: all, needs_you: needs_you}

        %{
          context
          | review: review,
            queue: if(context.scope == :needs_you, do: needs_you, else: all)
        }
      else
        context
      end

    socket = assign(socket, :workbench_context, context)

    if context && socket.assigns.workbench_period do
      invoices = Enum.map(context.queue, & &1.invoice)
      navigation = posting_navigation(invoices, invoice)

      navigation =
        if navigation.position == 0,
          do: %{navigation | next: List.first(invoices)},
          else: navigation

      assign(
        socket,
        :posting_navigation,
        navigation
      )
    else
      socket
    end
  end

  def totals(invoice), do: Invoice.extracted_totals(invoice)

  def review_queue_empty?(%{scope: :needs_you, queue: []}, period) when not is_nil(period),
    do: true

  def review_queue_empty?(_, _), do: false

  def place_of_supply_label(nil), do: "Not determined"
  def place_of_supply_label(""), do: "Not determined"

  def place_of_supply_label(code) do
    case Nila.Gst.StateCodes.name_for(code) do
      nil -> code
      name -> "#{name} (#{code})"
    end
  end

  def invoice_total_rows(invoice) do
    checks = Gstr1.invoice_checks(invoice)
    totals = Nila.Gst.Sales.InvoiceValidation.comparison_totals(invoice)
    printed_totals = Nila.Gst.Sales.Values.printed(invoice)

    for {label, field, code, calculated} <- [
          {"Taxable", :taxable, "printed_taxable_mismatch", totals.taxable},
          {"GST", :tax, "printed_tax_mismatch", totals.tax},
          {"Grand total", :total, "grand_total_mismatch", totals.total}
        ] do
      check = Enum.find(checks, &(&1["code"] == code))
      printed = printed_totals[field]
      mismatch? = check != nil && check["passed"] == false

      %{
        label: label,
        field: field,
        matches?: check != nil && check["passed"] == true,
        calculated: calculated,
        printed: printed,
        mismatch?: mismatch?,
        difference:
          if(mismatch?, do: Money.rupees(abs(Money.paise(printed) - Money.paise(calculated))))
      }
    end
  end

  def invoice_total(invoice) do
    amounts = totals(invoice)

    if is_number(amounts.taxable) and is_number(amounts.tax),
      do: amounts.taxable + amounts.tax
  end

  def rupees(value) do
    case Money.paise_or_error(value) do
      {:ok, paise} -> Nila.Formatters.format_money_with_paise(paise)
      _missing_or_unreadable -> "—"
    end
  end

  def working_number(value) when is_integer(value), do: Integer.to_string(value)

  def working_number(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  def working_number(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "—", else: value
  end

  def working_number(_value), do: "—"

  def money(paise), do: Nila.Formatters.format_money_with_paise(paise)

  def handle_event("request-send-to-tally", _params, socket) do
    if socket.assigns.packet.warnings == [] do
      send_to_tally(socket)
    else
      {:noreply, assign(socket, :confirming_tally_send, true)}
    end
  end

  def handle_event("cancel-send-to-tally", _params, socket),
    do: {:noreply, assign(socket, :confirming_tally_send, false)}

  def handle_event("send-to-tally", _params, socket), do: send_to_tally(socket)

  def handle_event("retry-failed-file", %{"dump-id" => dump_id}, socket) do
    with {dump_id, ""} <- Integer.parse(dump_id),
         %{} = dump <- Enum.find(socket.assigns.packet.failed_files, &(&1.id == dump_id)),
         {:ok, _dump} <-
           Nila.Repo.transact(fn ->
             with {:ok, retried} <- Dumps.retry_failed(dump),
                  {:ok, _job} <- Oban.insert(DumpWorker.new(%{dump_id: dump.id})) do
               {:ok, retried}
             end
           end) do
      {:noreply, reload_processing_result(socket)}
    else
      _reason -> {:noreply, put_flash(socket, :error, "Nila couldn't try that file again.")}
    end
  end

  def handle_event("verify-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyJobs.verify_indeterminate_by_sales_batch(
           org_id,
           socket.assigns.sales_batch.id
         ) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.sales_batch))
         |> assign(:send_error, nil)}

      _ ->
        {:noreply, assign(socket, :send_error, "Nila could not verify these vouchers in Tally.")}
    end
  end

  def handle_event("ensure-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyJobs.ensure_succeeded_by_sales_batch(
           org_id,
           socket.assigns.sales_batch.id
         ) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.sales_batch))
         |> assign(:send_error, nil)}

      _ ->
        {:noreply, assign(socket, :send_error, "Nila could not check these vouchers in Tally.")}
    end
  end

  def handle_event("close-posting-review", _params, socket) do
    if socket.assigns[:review_batch] do
      {:noreply, push_navigate(socket, to: batch_home_path(socket))}
    else
      if socket.assigns.workbench_period do
        {:noreply,
         push_navigate(socket,
           to:
             InvoiceWorkbench.return_path(
               socket.assigns.client.id,
               socket.assigns.workbench_period,
               socket.assigns.workbench_return_to
             )
         )}
      else
        {:noreply,
         push_patch(socket,
           to: batch_home_path(socket)
         )}
      end
    end
  end

  def handle_event("toggle-invoice-queue", _, socket),
    do: {:noreply, assign(socket, :invoice_queue_open?, not socket.assigns.invoice_queue_open?)}

  def handle_event("confirm-gst-issue", %{"target" => target}, socket) do
    context = socket.assigns.workbench_context

    issue =
      context &&
        Enum.find(
          context.item.actionable_issues,
          &(Nila.Gst.Sales.Workings.issue_key(&1) == target && &1["status"] == "open")
        )

    if issue && not Nila.Gst.Sales.Workings.blocking?(issue) do
      proposal =
        Nila.Gst.Proposals.for_issue(
          issue,
          Nila.Gst.Sales.Values.for_invoice(context.item.invoice, context.workings.derived),
          Gstr1.invoice_checks(context.item.invoice)
        )
        |> Nila.Gst.Proposals.freeze()

      attrs = %{
        "verb" => "confirm_issue",
        "target" => target,
        "payload" => %{"decision" => "use_extracted_lines", "proposal" => proposal}
      }

      case Nila.Gst.Sales.Resolutions.record(
             context.month,
             attrs,
             socket.assigns.current_scope.user.id
           ) do
        {:ok, _} ->
          {:noreply, socket |> refresh_workbench() |> close_line_editor()}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "This check could not be resolved. Refresh and try again.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove-invoice", %{"id" => source_id}, socket) do
    invoice = Enum.find(socket.assigns.packet.all_invoices, &(invoice_id(&1) == source_id))

    cond do
      is_nil(invoice) ->
        {:noreply, socket}

      invoice_frozen_now?(socket, invoice) ->
        {:noreply, put_flash(socket, :error, "Sent invoices cannot be changed.")}

      true ->
        scope = socket.assigns.current_scope

        case InvoiceRemovals.remove(
               scope.current_org.id,
               socket.assigns.client.id,
               socket.assigns.batch_ref,
               source_id,
               scope.user.id
             ) do
          {:ok, _removal} ->
            socket =
              socket
              |> reload_packet()
              |> put_flash(:info, "Invoice excluded. You can restore it later.")

            socket =
              if invoice_id(socket.assigns.selected_invoice) == source_id,
                do:
                  push_navigate(socket,
                    to:
                      if(socket.assigns.workbench_period,
                        do:
                          InvoiceWorkbench.return_path(
                            socket.assigns.client.id,
                            socket.assigns.workbench_period,
                            socket.assigns.workbench_return_to
                          ),
                        else: batch_home_path(socket)
                      )
                  ),
                else: socket

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "That invoice could not be excluded.")}
        end
    end
  end

  def handle_event("remove-invoice", _params, socket), do: {:noreply, socket}

  def handle_event("restore-invoice", %{"id" => source_id}, socket) do
    invoice = Enum.find(socket.assigns.packet.excluded, &(invoice_id(&1) == source_id))

    cond do
      is_nil(invoice) ->
        {:noreply, socket}

      invoice_frozen_now?(socket, invoice) ->
        {:noreply, put_flash(socket, :error, "Sent invoices cannot be changed.")}

      true ->
        scope = socket.assigns.current_scope

        case InvoiceRemovals.restore(
               scope.current_org.id,
               socket.assigns.client.id,
               socket.assigns.batch_ref,
               source_id,
               scope.user.id
             ) do
          {:ok, :restored} ->
            {:noreply, reload_packet(socket)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "That invoice could not be included.")}
        end
    end
  end

  def handle_event("open-posting-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, true)}

  def handle_event("close-posting-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, false)}

  def handle_event("edit-invoice-facts", params, socket) do
    if not invoice_frozen_now?(socket, socket.assigns.selected_invoice) do
      {:noreply,
       socket
       |> assign(:editing_invoice_facts?, true)
       |> assign(
         :invoice_facts_section,
         if(params["section"] == "totals", do: "totals", else: "details")
       )
       |> assign(
         :invoice_facts_form,
         to_form(invoice_facts_values(socket.assigns.posting_preview_invoice), as: :invoice_facts)
       )
       |> assign(:invoice_facts_focus, params["field"])
       |> assign(
         :invoice_facts_return_focus,
         params["return_to"] || "#sales-bill-edit-invoice-facts"
       )
       |> assign(:invoice_facts_error, nil)}
    else
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    end
  end

  def handle_event("close-invoice-facts", _params, socket),
    do: {:noreply, close_invoice_facts_editor(socket)}

  def handle_event(
        "save-invoice-facts",
        %{"invoice_facts" => attrs},
        %{
          assigns: %{
            selected_invoice: invoice,
            tally_posting: tally_posting,
            current_scope: current_scope
          }
        } = socket
      )
      when not is_nil(invoice) and not is_nil(tally_posting) do
    if not invoice_frozen_now?(socket, invoice) do
      org_id = current_scope.current_org.id
      source_id = Invoice.source_id(invoice)

      case InvoiceCorrections.save(
             org_id,
             socket.assigns.client.id,
             socket.assigns.batch_ref,
             source_id,
             attrs,
             current_scope.user.id
           ) do
        {:ok, %{invoice: corrected_invoice}} ->
          posting = put_invoice_facts(tally_posting.form.params, attrs)

          {:noreply,
           socket
           |> replace_selected_invoice(corrected_invoice, posting)
           |> close_invoice_facts_editor()}

        {:error, {:invalid_correction, _field, :invalid_number}} ->
          {:noreply,
           socket
           |> assign(:invoice_facts_form, to_form(attrs, as: :invoice_facts))
           |> assign(
             :invoice_facts_error,
             "Enter a valid amount of zero or more, such as ₹23,100.50."
           )}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:invoice_facts_form, to_form(attrs, as: :invoice_facts))
           |> assign(:invoice_facts_error, "Those invoice facts could not be saved.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    end
  end

  def handle_event("save-invoice-facts", _params, socket), do: {:noreply, socket}

  def handle_event("edit-narration", _params, socket),
    do: {:noreply, assign(socket, :editing_narration?, true)}

  def handle_event("finish-narration", _params, socket),
    do: {:noreply, assign(socket, :editing_narration?, false)}

  def handle_event("posting-evidence-page", %{"page" => page}, socket) do
    count = length(socket.assigns.selected_invoice["image_urls"] || [])

    case Integer.parse(to_string(page)) do
      {number, ""} when number >= 0 and number < count ->
        {:noreply, assign(socket, :evidence_page, number)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "preview-tally-posting",
        %{"tally_posting" => posting},
        %{assigns: %{selected_invoice: invoice, tally_posting: tally_posting}} = socket
      )
      when not is_nil(invoice) and not is_nil(tally_posting) do
    preview_invoice = preview_invoice(invoice, posting["invoice"] || %{})
    identities = posting["line_sales_ledger_identities"] || %{}

    line_rows =
      preview_line_rows(tally_posting.line_rows, preview_invoice, identities)

    tax_rows =
      Enum.map(tally_posting.tax_rows, fn row ->
        %{row | amount: tax_amount(preview_invoice, row.head)}
      end)

    tally_posting = %{
      tally_posting
      | form: to_form(posting, as: :tally_posting),
        line_rows: line_rows,
        tax_rows: tax_rows
    }

    {:noreply,
     socket
     |> assign(:posting_preview_invoice, preview_invoice)
     |> assign(:tally_posting, tally_posting)}
  end

  def handle_event("preview-tally-posting", _params, socket), do: {:noreply, socket}

  def handle_event("open-ledger-picker", %{"picker" => picker}, socket) do
    generation = socket.assigns.ledger_picker.generation + 1

    case ledger_picker(socket.assigns.tally_posting, picker, "", generation) do
      %{status: :open} = ledger_picker ->
        {:noreply, assign(socket, :ledger_picker, ledger_picker)}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "filter-ledger-picker",
        %{
          "ledger_picker" => %{
            "query" => query,
            "picker" => picker,
            "generation" => generation
          }
        },
        socket
      ) do
    if current_ledger_picker?(socket, picker, generation) do
      generation = socket.assigns.ledger_picker.generation

      {:noreply,
       assign(
         socket,
         :ledger_picker,
         ledger_picker(socket.assigns.tally_posting, picker, query, generation)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "choose-first-ledger",
        %{
          "ledger_picker" => %{
            "query" => query,
            "picker" => picker,
            "generation" => generation
          }
        },
        socket
      ) do
    if current_ledger_picker?(socket, picker, generation) do
      case ledger_picker(
             socket.assigns.tally_posting,
             picker,
             query,
             socket.assigns.ledger_picker.generation
           ).options do
        [{_label, identity} | _rest] -> choose_ledger(socket, picker, generation, identity)
        [] -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "choose-ledger",
        %{"identity" => identity, "picker" => picker, "generation" => generation},
        socket
      ) do
    choose_ledger(socket, picker, generation, identity)
  end

  def handle_event(
        "close-ledger-picker",
        %{"picker" => picker, "generation" => generation},
        socket
      ) do
    if current_ledger_picker?(socket, picker, generation) do
      {:noreply,
       assign(
         socket,
         :ledger_picker,
         empty_ledger_picker(socket.assigns.ledger_picker.generation)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, _params, socket)
      when event in ~w(filter-ledger-picker choose-first-ledger choose-ledger close-ledger-picker),
      do: {:noreply, socket}

  def handle_event("edit-posting-line", %{"index" => index}, socket) do
    if not invoice_frozen_now?(socket, socket.assigns.selected_invoice) do
      with {index, ""} <- Integer.parse(to_string(index)),
           true <- index >= 0,
           %{} = row <- Enum.at(socket.assigns.tally_posting.line_rows, index) do
        {:noreply,
         socket
         |> assign(:editing_line_index, index)
         |> assign(:line_edit_row, row)
         |> assign(:line_edit_form, to_form(line_edit_values(row), as: :line_edit))
         |> assign(:line_edit_error, nil)}
      else
        _invalid -> {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    end
  end

  def handle_event("close-posting-line", _params, socket),
    do: {:noreply, close_line_editor(socket)}

  def handle_event(
        "save-posting-line",
        %{"line_edit" => attrs},
        %{
          assigns: %{
            editing_line_index: index,
            selected_invoice: invoice,
            current_scope: current_scope
          }
        } = socket
      )
      when is_integer(index) and not is_nil(invoice) do
    if not invoice_frozen_now?(socket, invoice) do
      org_id = current_scope.current_org.id
      source_id = Invoice.source_id(invoice)
      changes = %{"line_items" => %{to_string(index) => attrs}}

      case InvoiceCorrections.save(
             org_id,
             socket.assigns.client.id,
             socket.assigns.batch_ref,
             source_id,
             changes,
             current_scope.user.id
           ) do
        {:ok, %{invoice: corrected_invoice}} ->
          posting = put_line_edit(socket.assigns.tally_posting.form.params, index, attrs)

          {:noreply,
           socket
           |> replace_selected_invoice(corrected_invoice, posting)
           |> close_line_editor()}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(:line_edit_form, to_form(attrs, as: :line_edit))
           |> assign(:line_edit_error, "That invoice line could not be saved.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    end
  end

  def handle_event("save-posting-line", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save-tally-posting",
        %{"tally_posting" => posting} = params,
        %{
          assigns: %{
            tally_company: %{id: company_id},
            tally_masters_available?: true,
            selected_invoice: invoice
          }
        } = socket
      )
      when not is_nil(invoice) do
    if invoice_frozen_now?(socket, invoice) do
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    else
      save_tally_posting(socket, posting, params, company_id, invoice)
    end
  end

  def handle_event("save-tally-posting", _params, socket), do: {:noreply, socket}

  defp send_to_tally(socket) do
    socket = assign(socket, :confirming_tally_send, false)
    org_id = socket.assigns.current_scope.current_org.id
    company = socket.assigns.tally_company

    with %{} <- company,
         true <- socket.assigns.tally_masters_available?,
         {:ok, company} <- online_tally_company(org_id, socket.assigns.client.id, company.id),
         :ok <- TallyPrime.validate_company_gstin(company, socket.assigns.client.gstin),
         {:ok, invoices, unresolved_parties} <-
           apply_tally_posting(org_id, company.id, socket.assigns.packet.invoices),
         {items, unbuildable} <- build_tally_items(invoices, company.name),
         {ready, blocked} <- partition_ready_items(company.id, items),
         {:ok, batch} <-
           Batch.pin_destination(org_id, socket.assigns.sales_batch.id, company.id),
         {:ok, _jobs} <-
           TallyJobs.enqueue_vouchers(company, ready,
             source_prefix: Batch.source_prefix(batch),
             sales_batch_id: batch.id
           ) do
      {:noreply,
       socket
       |> assign(:sales_batch, batch)
       |> assign(:tally_company, company)
       |> assign(:tally_jobs, list_tally_jobs(org_id, batch))
       |> assign(:send_holds, send_holds(unresolved_parties, unbuildable, blocked))
       |> assign(:send_error, send_blocked_message(unresolved_parties, unbuildable, blocked))}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:tally_online?, false)
         |> assign(
           :send_error,
           "#{company.name} is unavailable. Reconnect it in TallyPrime, then try again."
         )}

      false ->
        {:noreply,
         assign(
           socket,
           :send_error,
           "Sync this Tally company's masters before sending vouchers."
         )}

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

      {:error, :stale_tally_posting_profile} ->
        {:noreply,
         assign(
           socket,
           :send_error,
           "A saved posting ledger is no longer in this Tally company. Sync masters and review the posting selections."
         )}

      _error ->
        {:noreply, assign(socket, :send_error, "Nila could not send these vouchers to Tally.")}
    end
  end

  defp save_tally_posting(socket, posting, _params, company_id, invoice) do
    org_id = socket.assigns.current_scope.current_org.id

    profile_attrs =
      Map.take(
        posting,
        ~w(sales_ledger_identity cgst_ledger_identity sgst_ledger_identity igst_ledger_identity)
      )

    profile_attrs =
      case line_sales_ledger_identity(posting) do
        {:ok, identity} -> Map.put(profile_attrs, "sales_ledger_identity", identity)
        _none_or_mixed -> profile_attrs
      end

    profile_attrs =
      case first_line_sales_ledger_identity(posting) do
        nil -> profile_attrs
        identity -> Map.put_new(profile_attrs, "sales_ledger_identity", identity)
      end

    with {:ok, %{invoice: corrected_invoice, sales_batch: batch}} <-
           InvoiceCorrections.save_batch_workbench(
             org_id,
             socket.assigns.client.id,
             socket.assigns.batch_ref,
             socket.assigns.sales_batch.id,
             Invoice.source_id(invoice),
             company_id,
             %{
               invoice: posting["invoice"] || editable_invoice_values(invoice),
               party_ledger_identity: posting["party_ledger_identity"],
               posting_profile: profile_attrs,
               line_sales_ledger_identities: posting["line_sales_ledger_identities"] || %{}
             },
             socket.assigns.current_scope.user.id
           ) do
      socket =
        socket
        |> assign(:sales_batch, batch)
        |> replace_selected_invoice(corrected_invoice)

      destination =
        case {socket.assigns.review_mode?, socket.assigns.required_mapping_invoices} do
          {true, [next_invoice | _]} ->
            posting_review_path(
              socket.assigns.client,
              socket.assigns.batch_ref,
              next_invoice,
              true,
              true,
              socket.assigns.source_dumps
            )

          _finished_or_direct ->
            batch_home_path(socket)
        end

      socket = put_flash(socket, :info, "Tally posting saved.")

      if is_nil(socket.assigns[:review_batch]) or not socket.assigns.review_mode? or
           socket.assigns.required_mapping_invoices == [] do
        handle_event("close-posting-review", %{}, socket)
      else
        {:noreply, push_patch(socket, to: destination)}
      end
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That Tally posting could not be saved.")}
    end
  end

  defp replace_selected_invoice(socket, corrected_invoice) do
    source_id = Invoice.source_id(corrected_invoice)
    socket = reload_packet(socket)
    corrected_invoice = find_packet_invoice(socket.assigns.packet, source_id, corrected_invoice)

    socket
    |> assign(:selected_invoice, corrected_invoice)
    |> assign(
      :selected_review,
      if(socket.assigns.accounting_view?,
        do: selected_review(socket.assigns.packet, corrected_invoice)
      )
    )
    |> assign(:posting_preview_invoice, corrected_invoice)
    |> assign(
      :posting_navigation,
      posting_navigation(socket.assigns.packet.all_invoices, corrected_invoice)
    )
    |> assign(:tally_posting, tally_posting(socket.assigns, corrected_invoice))
    |> refresh_workbench()
  end

  defp replace_selected_invoice(socket, corrected_invoice, posting) do
    source_id = Invoice.source_id(corrected_invoice)
    socket = reload_packet(socket)
    corrected_invoice = find_packet_invoice(socket.assigns.packet, source_id, corrected_invoice)

    preview_invoice = preview_invoice(corrected_invoice, posting["invoice"] || %{})
    identities = posting["line_sales_ledger_identities"] || %{}
    current_posting = socket.assigns.tally_posting

    line_rows =
      preview_line_rows(current_posting.line_rows, preview_invoice, identities)

    tax_rows =
      Enum.map(current_posting.tax_rows, fn row ->
        %{row | amount: tax_amount(preview_invoice, row.head)}
      end)

    tally_posting = %{
      current_posting
      | form: to_form(posting, as: :tally_posting),
        line_rows: line_rows,
        tax_rows: tax_rows
    }

    socket
    |> assign(:selected_invoice, corrected_invoice)
    |> assign(
      :selected_review,
      if(socket.assigns.accounting_view?,
        do: selected_review(socket.assigns.packet, corrected_invoice)
      )
    )
    |> assign(:posting_preview_invoice, preview_invoice)
    |> assign(
      :posting_navigation,
      posting_navigation(socket.assigns.packet.all_invoices, corrected_invoice)
    )
    |> assign(:tally_posting, tally_posting)
    |> refresh_workbench()
  end

  defp close_line_editor(socket) do
    socket
    |> assign(:editing_line_index, nil)
    |> assign(:line_edit_row, nil)
    |> assign(:line_edit_form, nil)
    |> assign(:line_edit_error, nil)
  end

  defp close_invoice_facts_editor(socket) do
    socket
    |> assign(:editing_invoice_facts?, false)
    |> assign(:invoice_facts_form, nil)
    |> assign(:invoice_facts_focus, nil)
    |> assign(:invoice_facts_return_focus, nil)
    |> assign(:invoice_facts_error, nil)
  end

  defp put_invoice_facts(posting, attrs) do
    posting = posting || %{}
    invoice = Map.get(posting, "invoice", %{})
    Map.put(posting, "invoice", Map.merge(invoice, attrs))
  end

  defp put_line_edit(posting, index, attrs) do
    posting = posting || %{}
    invoice = Map.get(posting, "invoice", %{})
    lines = Map.get(invoice, "line_items", %{})

    posting
    |> Map.put("invoice", Map.put(invoice, "line_items", Map.put(lines, to_string(index), attrs)))
  end

  defp line_edit_values(row) do
    line = row.line

    %{
      "description" => line["description"] || line["item_name"],
      "hsn_sac" => line["hsn_sac"],
      "quantity" => line["quantity"],
      "uom" => line["uom"],
      "rate" => line["printed_unit_price"] || line["unit_price"] || line["rate"],
      "taxable_value" => line["taxable_value"]
    }
    |> then(fn values ->
      Enum.reduce(editable_line_tax_rows(row), values, fn tax, current ->
        current
        |> Map.put("#{tax.head}_rate", tax.rate)
        |> Map.put("#{tax.head}_amount", tax.amount)
      end)
    end)
  end

  defp invoice_facts_values(invoice) do
    invoice = invoice || %{}

    invoice
    |> Map.take(~w(invoice_number invoice_date buyer_name buyer_gstin place_of_supply
         printed_total_taxable printed_total_tax printed_grand_total))
    |> Map.put("printed_total_tax", Nila.Gst.Sales.Values.printed(invoice).tax)
  end

  def tax_edit_field("cgst", :rate), do: :cgst_rate
  def tax_edit_field("cgst", :amount), do: :cgst_amount
  def tax_edit_field("sgst", :rate), do: :sgst_rate
  def tax_edit_field("sgst", :amount), do: :sgst_amount
  def tax_edit_field("igst", :rate), do: :igst_rate
  def tax_edit_field("igst", :amount), do: :igst_amount

  defp editable_invoice_values(invoice) do
    %{
      "invoice_number" => invoice["invoice_number"],
      "invoice_date" => invoice["invoice_date"],
      "buyer_name" => invoice["buyer_name"],
      "buyer_gstin" => invoice["buyer_gstin"],
      "narration" => narration(invoice),
      "line_items" =>
        invoice
        |> Map.get("line_items", [])
        |> Enum.map(fn line ->
          Map.take(
            line,
            ~w(description item_name hsn_sac quantity uom printed_unit_price taxable_value cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount)
          )
        end)
    }
  end

  defp preview_invoice(invoice, changes) do
    invoice =
      Enum.reduce(
        ~w(invoice_number invoice_date buyer_name buyer_gstin narration),
        invoice,
        fn field, current ->
          if Map.has_key?(changes, field),
            do: Map.put(current, field, changes[field]),
            else: current
        end
      )

    case changes["line_items"] do
      lines when is_map(lines) ->
        Enum.reduce(lines, invoice, fn {index, fields}, current ->
          with {index, ""} <- Integer.parse(to_string(index)),
               true <- is_map(fields) do
            Map.update(current, "line_items", [], fn existing ->
              List.update_at(existing, index, &preview_line(&1, fields))
            end)
          else
            _invalid -> current
          end
        end)

      _missing ->
        invoice
    end
  end

  defp preview_line(line, fields) do
    numeric =
      ~w(quantity rate taxable_value cgst_rate cgst_amount sgst_rate sgst_amount igst_rate igst_amount)

    Enum.reduce(fields, line, fn {field, value}, current ->
      numeric? = field in numeric
      field = if field == "rate", do: "printed_unit_price", else: field
      value = if numeric?, do: preview_number(value), else: value
      Map.put(current, field, value)
    end)
  end

  defp preview_number(value) when is_number(value), do: value
  defp preview_number(value) when is_binary(value), do: Money.rupee_number(value)

  defp preview_number(_value), do: nil

  defp preview_line_rows(current_rows, invoice, identities) do
    invoice
    |> Map.get("line_items", [])
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      current = Enum.at(current_rows, index) || %{}

      %{
        index: index,
        line: line,
        sales_ledger_identity:
          Map.get(identities, to_string(index), current[:sales_ledger_identity]),
        tax_rows: line_tax_rows(line)
      }
    end)
  end

  defp line_tax_rows(line) do
    ~w(cgst sgst igst)
    |> Enum.filter(fn head ->
      positive?(line["#{head}_rate"]) or positive?(line["#{head}_amount"])
    end)
    |> Enum.map(fn head ->
      %{
        head: head,
        label: String.upcase(head),
        rate: line["#{head}_rate"],
        amount: line["#{head}_amount"]
      }
    end)
  end

  def editable_line_tax_rows(%{tax_rows: []} = row) do
    for head <- ~w(cgst sgst igst) do
      %{
        head: head,
        label: String.upcase(head),
        rate: row.line["#{head}_rate"],
        amount: row.line["#{head}_amount"]
      }
    end
  end

  def editable_line_tax_rows(row), do: row.tax_rows

  defp voucher_numbering_error(issues) do
    types = issues |> Enum.map(& &1.voucher_type) |> Enum.uniq() |> Enum.join(", ")

    "#{types} voucher numbering in Tally must be Manual or Automatic (Manual Override). Change it in Tally, sync the company, then retry."
  end

  def handle_info(
        {:gst_dump_progress, dump_id, _client_id, _period, "sales", message},
        socket
      ) do
    case socket.assigns.processing_jobs do
      %{^dump_id => job} = jobs ->
        jobs = Map.put(jobs, dump_id, apply_processing_progress(job, message))
        socket = assign(socket, :processing_jobs, jobs)

        {:noreply, if(processing?(jobs), do: socket, else: reload_processing_result(socket))}

      _not_this_batch ->
        {:noreply, socket}
    end
  end

  def handle_info(:tally_jobs_changed, socket) do
    {:noreply,
     assign(
       socket,
       :tally_jobs,
       list_tally_jobs(
         socket.assigns.current_scope.current_org.id,
         socket.assigns.sales_batch
       )
     )}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff"},
        socket
      ) do
    org_id = socket.assigns.current_scope.current_org.id
    company = tally_destination(org_id, socket.assigns.client.id, socket.assigns.sales_batch)

    {:noreply,
     socket
     |> assign(:tally_company, company)
     |> assign_tally_availability(org_id, company)}
  end

  def remainder(packet, tally_jobs) do
    unread = Enum.map(packet.unread_pages, &"#{&1.file} · page #{&1.page}")

    not_added =
      tally_jobs
      |> Enum.filter(&(&1.status in ["failed", "indeterminate"]))
      |> Enum.map(&(&1.payload["invoice_number"] || "Unnumbered bill"))

    missing_jobs = missing_job_invoice_numbers(packet.invoices, tally_jobs)

    Enum.uniq(unread ++ not_added ++ missing_jobs)
  end

  defp missing_job_invoice_numbers(_invoices, []), do: []

  defp missing_job_invoice_numbers(invoices, tally_jobs) do
    invoices
    |> Enum.reject(&selected_tally_job(tally_jobs, &1, invoices))
    |> Enum.map(& &1["invoice_number"])
  end

  defp list_tally_jobs(org_id, %Batch{id: batch_id}),
    do: TallyJobs.list_by_sales_batch(org_id, batch_id)

  defp online_tally_companies(org_id) do
    online_device_ids =
      "tally_devices:#{org_id}"
      |> Presence.list()
      |> Map.keys()
      |> Enum.reduce(MapSet.new(), fn device_id, ids ->
        case Integer.parse(device_id) do
          {id, ""} -> MapSet.put(ids, id)
          _invalid -> ids
        end
      end)

    org_id
    |> TallyDevices.list_open_company_routes()
    |> Enum.filter(&MapSet.member?(online_device_ids, &1.device_id))
  end

  defp tally_presence_topic(org_id), do: "tally_devices:#{org_id}"

  defp tally_destination(org_id, client_id, %Batch{tally_company_id: company_id}) do
    case company_id do
      nil ->
        case TallyDevices.get_client_company(org_id, client_id) do
          {:ok, company} -> company
          {:error, :not_found} -> nil
        end

      company_id ->
        case TallyDevices.get_company(org_id, company_id) do
          {:ok, company} -> company
          {:error, :not_found} -> nil
        end
    end
  end

  defp tally_masters(_org_id, nil), do: []
  defp tally_masters(org_id, company), do: TallyMappings.list_ledger_choices(org_id, company.id)

  defp latest_master_sync([]), do: nil

  defp latest_master_sync(masters) do
    masters
    |> Enum.map(& &1.updated_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp assign_tally_availability(socket, _org_id, nil) do
    socket
    |> assign(:tally_device_online?, false)
    |> assign(:tally_company_open?, false)
    |> assign(:tally_online?, false)
  end

  defp assign_tally_availability(socket, org_id, company) do
    online_company = online_tally_company(org_id, socket.assigns.client.id, company.id)
    online? = match?({:ok, _company}, online_company)

    socket
    |> assign(:tally_device_online?, online?)
    |> assign(:tally_company_open?, online?)
    |> assign(:tally_online?, online?)
  end

  defp online_tally_company(org_id, _client_id, company_id) do
    case Enum.find(online_tally_companies(org_id), &(&1.id == company_id)) do
      nil -> {:error, :not_found}
      company -> {:ok, company}
    end
  end

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

  defp send_blocked_message([], [], []), do: nil

  defp send_blocked_message(unresolved_parties, unbuildable, blocked_ledgers) do
    messages =
      [
        unresolved_parties_message(unresolved_parties),
        unbuildable_message(unbuildable),
        missing_ledgers_message(blocked_ledgers)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(messages, " ")
  end

  defp unresolved_parties_message([]), do: nil

  defp unresolved_parties_message(parties) do
    labels = parties |> Enum.map(& &1.label) |> Enum.join(", ")
    "Choose an existing Tally party for #{labels} before sending."
  end

  defp unbuildable_message([]), do: nil

  defp unbuildable_message(invoices) do
    labels = invoices |> Enum.map(& &1.label) |> Enum.join(", ")
    "Nila could not prepare #{labels} as Tally vouchers."
  end

  defp send_holds(unresolved_parties, unbuildable, blocked_ledgers) do
    unresolved = Enum.map(unresolved_parties, &{&1.source_id, :needs_review})
    unbuildable = Enum.map(unbuildable, &{&1.source_id, :cannot_send})

    missing_ledgers =
      Enum.map(blocked_ledgers, fn blocked ->
        {blocked.invoice_source_id, :needs_review}
      end)

    Map.new(unresolved ++ unbuildable ++ missing_ledgers)
  end

  defp current_send_holds(_org_id, nil, _packet), do: %{}

  defp current_send_holds(org_id, company, packet) do
    with {:ok, invoices, unresolved_parties} <-
           apply_tally_posting(org_id, company.id, packet.invoices) do
      {items, unbuildable} = build_tally_items(invoices, company.name)
      {_ready, blocked} = partition_ready_items(company.id, items)
      send_holds(unresolved_parties, unbuildable, blocked)
    else
      _error -> %{}
    end
  end

  def plural(1, singular), do: singular
  def plural(_count, singular), do: singular <> "s"

  defp apply_tally_posting(org_id, company_id, invoices) do
    ledgers = TallyMappings.list_ledger_choices(org_id, company_id)
    ledgers_by_identity = Map.new(ledgers, &{&1.identity, &1.name})

    profile =
      case TallyMappings.get_posting_profile(org_id, company_id) do
        {:ok, profile} -> profile
        {:error, :not_found} -> nil
      end

    with {:ok, profile_posting} <- profile_posting(profile, ledgers_by_identity) do
      {resolved, unresolved} =
        apply_party_posting(org_id, company_id, invoices, profile_posting)

      {:ok, resolved, unresolved}
    end
  end

  defp apply_party_posting(org_id, company_id, invoices, profile_posting) do
    {resolved, unresolved} =
      Enum.reduce(invoices, {[], []}, fn invoice, {resolved, unresolved} ->
        if Gstr1.recipient_registration(invoice) == "registered" do
          case TallyMappings.resolve_party(org_id, company_id, party_identity(invoice)) do
            {:ok, %{ledger: ledger}} ->
              posting =
                profile_posting
                |> Map.put("party_ledger", ledger.name)
                |> Map.put(
                  "line_sales_ledgers",
                  resolved_line_sales_ledgers(org_id, company_id, invoice)
                )

              {[Map.put(invoice, "tally_posting", posting) | resolved], unresolved}

            {:error, _reason} ->
              {resolved,
               [
                 %{source_id: Invoice.source_id(invoice), label: invoice_label(invoice)}
                 | unresolved
               ]}
          end
        else
          posting =
            Map.put(
              profile_posting,
              "line_sales_ledgers",
              resolved_line_sales_ledgers(org_id, company_id, invoice)
            )

          {[Map.put(invoice, "tally_posting", posting) | resolved], unresolved}
        end
      end)

    {Enum.reverse(resolved), unresolved |> Enum.reverse() |> Enum.uniq()}
  end

  defp build_tally_items(invoices, company_name) do
    Enum.reduce(invoices, {[], []}, fn invoice, {items, blocked} ->
      case TallyPrime.build_items_for_company(%{active_invoices: [invoice]}, company_name) do
        {:ok, [item]} ->
          item = Map.put(item, :invoice_source_id, Invoice.source_id(invoice))
          {[item | items], blocked}

        {:error, reason} ->
          {items,
           [
             %{
               source_id: Invoice.source_id(invoice),
               label: invoice_label(invoice),
               reason: reason
             }
             | blocked
           ]}
      end
    end)
    |> then(fn {items, blocked} -> {Enum.reverse(items), Enum.reverse(blocked)} end)
  end

  defp resolved_line_sales_ledgers(org_id, company_id, invoice) do
    invoice
    |> Map.get("line_items", [])
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, index}, ledgers ->
      case TallyMappings.resolve_sales_ledger(org_id, company_id, line) do
        {:ok, %{ledger: ledger}} -> Map.put(ledgers, Integer.to_string(index), ledger.name)
        {:error, _reason} -> ledgers
      end
    end)
  end

  defp invoice_label(invoice) do
    invoice["invoice_number"] || invoice["buyer_name"] || "an unnumbered invoice"
  end

  defp profile_posting(nil, _ledgers_by_identity), do: {:ok, %{}}

  defp profile_posting(profile, ledgers_by_identity) do
    fields = [
      {:sales_ledger_identity, "sales_ledger"},
      {:cgst_ledger_identity, "cgst_ledger"},
      {:sgst_ledger_identity, "sgst_ledger"},
      {:igst_ledger_identity, "igst_ledger"}
    ]

    Enum.reduce_while(fields, {:ok, %{}}, fn {field, posting_key}, {:ok, posting} ->
      case Map.fetch!(profile, field) do
        nil ->
          {:cont, {:ok, posting}}

        identity ->
          case Map.fetch(ledgers_by_identity, identity) do
            {:ok, name} -> {:cont, {:ok, Map.put(posting, posting_key, name)}}
            :error -> {:halt, {:error, :stale_tally_posting_profile}}
          end
      end
    end)
  end

  defp party_identity(invoice) do
    %{
      gstin: invoice["buyer_gstin"],
      name: invoice["buyer_name"],
      source_key: invoice["id"] || invoice["invoice_number"]
    }
  end

  def posting_review_path(client, batch_ref, invoice, review_mode?, accounting?, dumps) do
    source_id = invoice_id(invoice)

    dump =
      Enum.find(dumps, fn dump ->
        Enum.any?(dump.invoices || [], &(Invoice.source_id(&1) == source_id))
      end)

    if dump do
      params = %{"batch" => batch_ref, "scope" => if(review_mode?, do: "needs_you", else: "all")}
      params = if accounting?, do: Map.put(params, "view", "accounting"), else: params

      "/gst/#{client.id}/#{dump.period}/sales/invoices/#{URI.encode_www_form(source_id)}?#{URI.encode_query(params)}"
    end
  end

  defp tally_posting(_assigns, nil), do: nil

  defp tally_posting(assigns, invoice) do
    org_id = assigns.current_scope.current_org.id
    company = assigns.tally_company
    choices = assigns.tally_masters

    {party, profile} =
      case company do
        nil ->
          {nil, nil}

        company ->
          {resolved_party(org_id, company.id, invoice), posting_profile(org_id, company.id)}
      end

    values = %{
      "party_ledger_identity" => party && party.ledger.identity,
      "sales_ledger_identity" =>
        profile_value(profile, :sales_ledger_identity) || default_identity(choices, "Sales"),
      "cgst_ledger_identity" =>
        profile_value(profile, :cgst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company, :cgst),
      "sgst_ledger_identity" =>
        profile_value(profile, :sgst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company, :sgst),
      "igst_ledger_identity" =>
        profile_value(profile, :igst_ledger_identity) ||
          resolved_tax_ledger_identity(org_id, company, :igst)
    }

    line_rows =
      invoice
      |> Map.get("line_items", [])
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        %{
          index: index,
          line: line,
          sales_ledger_identity:
            resolved_sales_identity(org_id, company, line) || values["sales_ledger_identity"],
          tax_rows: line_tax_rows(line)
        }
      end)

    tax_rows =
      ~w(cgst sgst igst)
      |> Enum.filter(&MapSet.member?(applicable_tax_heads(invoice), &1))
      |> Enum.map(fn head ->
        %{
          head: head,
          label: String.upcase(head),
          amount: tax_amount(invoice, head),
          field: tax_ledger_field(head),
          identity: values["#{head}_ledger_identity"]
        }
      end)

    %{
      company: company,
      party_choices: ledger_options(choices, &TallyMappings.party_ledger?/1),
      sales_choices: ledger_options(choices, &TallyMappings.sales_ledger?/1),
      tax_choices:
        Map.new(~w(cgst sgst igst), fn head ->
          {head,
           ledger_options(choices, fn ledger ->
             TallyMappings.tax_ledger_for_head?(ledger, head)
           end)}
        end),
      form: to_form(values, as: :tally_posting),
      line_rows: line_rows,
      tax_rows: tax_rows
    }
  end

  defp refresh_required_mapping_invoices(%{assigns: %{tally_masters_available?: false}} = socket) do
    invoices =
      Enum.reject(socket.assigns.packet.invoices, fn invoice ->
        invoice_frozen?(socket.assigns.tally_jobs, invoice, socket.assigns.packet.all_invoices)
      end)

    socket
    |> assign(:required_mapping_invoices, invoices)
    |> assign(:required_mapping_counts, %{})
  end

  defp refresh_required_mapping_invoices(socket) do
    invoices_with_counts =
      socket.assigns.packet.invoices
      |> Enum.reject(fn invoice ->
        invoice_frozen?(
          socket.assigns.tally_jobs,
          invoice,
          socket.assigns.packet.all_invoices
        )
      end)
      |> Enum.map(fn invoice ->
        requirement_count =
          socket.assigns
          |> tally_posting(invoice)
          |> posting_requirements()
          |> length()

        {invoice, requirement_count}
      end)
      |> Enum.reject(fn {_invoice, requirement_count} -> requirement_count == 0 end)

    socket
    |> assign(:required_mapping_invoices, Enum.map(invoices_with_counts, &elem(&1, 0)))
    |> assign(
      :required_mapping_counts,
      Map.new(invoices_with_counts, fn {invoice, count} -> {Invoice.source_id(invoice), count} end)
    )
  end

  def posting_requirements(nil), do: []

  def posting_requirements(posting) do
    party =
      if not valid_ledger_identity?(
           posting.form[:party_ledger_identity].value,
           posting.party_choices
         ) do
        [
          %{
            key: :party_ledger,
            label: "Choose the Tally party ledger",
            picker: "party"
          }
        ]
      else
        []
      end

    sales =
      posting.line_rows
      |> Enum.reject(&valid_ledger_identity?(&1.sales_ledger_identity, posting.sales_choices))
      |> Enum.map(fn row ->
        description = row.line["description"] || row.line["item_name"] || "unnamed line"

        %{
          key: {:sales_ledger, row.index},
          label: "Choose the sales ledger for “#{description}”",
          picker: "sales:#{row.index}"
        }
      end)

    tax =
      posting.tax_rows
      |> Enum.reject(fn row ->
        valid_ledger_identity?(
          posting.form[row.field].value,
          Map.get(posting.tax_choices, row.head, [])
        )
      end)
      |> Enum.map(fn row ->
        %{
          key: {:tax_ledger, row.head},
          label: "Choose the #{row.label} ledger",
          picker: "tax:#{row.head}"
        }
      end)

    party ++ sales ++ tax
  end

  def next_posting_requirement(posting), do: List.first(posting_requirements(posting))

  def ready_invoice_count(packet, required_mapping_invoices) do
    max(
      length(packet.invoices) - length(attention_invoices(packet, required_mapping_invoices)),
      0
    )
  end

  def attention_invoices(packet, required_mapping_invoices) do
    attention_ids =
      packet.needs_review
      |> Enum.map(&Invoice.source_id(&1.invoice))
      |> Kernel.++(Enum.map(required_mapping_invoices, &Invoice.source_id/1))
      |> MapSet.new()

    Enum.filter(packet.invoices, &(Invoice.source_id(&1) in attention_ids))
  end

  def attention_invoice_count(packet, required_mapping_invoices) do
    packet.needs_review
    |> Enum.map(&Invoice.source_id(&1.invoice))
    |> Kernel.++(Enum.map(required_mapping_invoices, &Invoice.source_id/1))
    |> Enum.uniq()
    |> length()
  end

  def batch_result_title(packet, required_mapping_invoices) do
    ready = ready_invoice_count(packet, required_mapping_invoices)
    attention = attention_invoice_count(packet, required_mapping_invoices)

    cond do
      ready == 0 and attention == 1 -> "1 invoice needs attention"
      ready == 0 and attention > 1 -> "#{attention} invoices need attention"
      ready == 0 -> "No sales vouchers ready"
      ready == 1 -> "1 sales voucher ready"
      true -> "#{ready} sales vouchers ready"
    end
  end

  def attention_summary(packet, required_mapping_invoices) do
    mapping_ids = MapSet.new(required_mapping_invoices, &Invoice.source_id/1)
    review_ids = MapSet.new(packet.needs_review, &Invoice.source_id(&1.invoice))
    overlap = mapping_ids |> MapSet.intersection(review_ids) |> MapSet.size()
    review_only = MapSet.size(review_ids) - overlap

    review_label =
      if Enum.all?(packet.needs_review, &tax_review_case?/1), do: "tax review", else: "review"

    [
      count_work(MapSet.size(mapping_ids), "needs Tally mappings", "need Tally mappings"),
      count_work(overlap, "also needs #{review_label}", "also need #{review_label}"),
      count_work(review_only, "needs #{review_label}", "need #{review_label}"),
      excluded_summary(packet)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp count_work(0, _singular, _plural), do: nil
  defp count_work(1, singular, _plural), do: "1 #{singular}"
  defp count_work(count, _singular, plural), do: "#{count} #{plural}"

  def excluded_summary(%{excluded: []}), do: nil
  def excluded_summary(packet), do: "#{length(packet.excluded)} excluded"

  def batch_table_invoices(packet) do
    Enum.reject(packet.all_invoices, &excluded_invoice?(packet, &1)) ++ packet.excluded
  end

  def excluded_invoice?(packet, invoice) do
    Enum.any?(packet.excluded, &(Invoice.source_id(&1) == Invoice.source_id(invoice)))
  end

  def batch_home_path(socket) do
    base = ~p"/sales-bills/#{socket.assigns.client.id}/batch/#{socket.assigns.batch_ref}"
    if socket.assigns.accounting_view?, do: base <> "?view=accounting", else: base
  end

  def batch_row_path(packet, client, batch_ref, invoice, accounting?, dumps) do
    if excluded_invoice?(packet, invoice),
      do: nil,
      else: posting_review_path(client, batch_ref, invoice, false, accounting?, dumps)
  end

  def batch_row_class(packet, invoice) do
    if excluded_invoice?(packet, invoice), do: "bg-quiet text-ink-muted"
  end

  def ready_totals(packet, required_mapping_invoices) do
    attention_ids =
      packet
      |> attention_invoices(required_mapping_invoices)
      |> MapSet.new(&Invoice.source_id/1)

    packet.invoices
    |> Enum.reject(&(Invoice.source_id(&1) in attention_ids))
    |> Enum.reduce(%{taxable_paise: 0, tax_paise: 0}, fn invoice, amounts ->
      invoice_totals = Invoice.extracted_totals_paise(invoice)

      %{
        taxable_paise: amounts.taxable_paise + (invoice_totals.taxable_paise || 0),
        tax_paise: amounts.tax_paise + invoice_totals.tax_paise
      }
    end)
  end

  defp required_mapping_invoice?(invoices, invoice) do
    Enum.any?(invoices, &(Invoice.source_id(&1) == Invoice.source_id(invoice)))
  end

  defp resolved_party(org_id, company_id, invoice) do
    case TallyMappings.resolve_party(org_id, company_id, party_identity(invoice)) do
      {:ok, match} -> match
      {:error, _reason} -> nil
    end
  end

  defp resolved_sales_identity(org_id, company_id, line) when is_integer(company_id) do
    case TallyMappings.resolve_sales_ledger(org_id, company_id, line) do
      {:ok, %{ledger: ledger}} -> ledger.identity
      {:error, _reason} -> nil
    end
  end

  defp resolved_sales_identity(_org_id, nil, _line), do: nil

  defp resolved_sales_identity(org_id, company, line),
    do: resolved_sales_identity(org_id, company.id, line)

  defp resolved_tax_ledger_identity(org_id, company_id, head) when is_integer(company_id) do
    case TallyMappings.resolve_tax_ledger(org_id, company_id, head) do
      {:ok, %{ledger: ledger}} -> ledger.identity
      {:error, _reason} -> nil
    end
  end

  defp resolved_tax_ledger_identity(_org_id, nil, _head), do: nil

  defp resolved_tax_ledger_identity(org_id, company, head),
    do: resolved_tax_ledger_identity(org_id, company.id, head)

  defp posting_profile(org_id, company_id) do
    case TallyMappings.get_posting_profile(org_id, company_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  defp profile_value(nil, _field), do: nil
  defp profile_value(profile, field), do: Map.get(profile, field)

  defp default_identity(choices, canonical_name) do
    canonical = String.downcase(canonical_name)

    case Enum.filter(choices, &(String.downcase(String.trim(&1.name)) == canonical)) do
      [choice] -> choice.identity
      _ -> nil
    end
  end

  defp ledger_options(choices, predicate) when is_function(predicate, 1) do
    choices
    |> Enum.filter(predicate)
    |> Enum.map(&{&1.name, &1.identity})
  end

  defp empty_ledger_picker(generation \\ 0) do
    %{
      status: :closed,
      picker: nil,
      trigger_id: nil,
      generation: generation,
      title: "Choose ledger",
      form: to_form(%{"query" => ""}, as: :ledger_picker),
      options: [],
      selected_identity: nil
    }
  end

  defp ledger_picker(nil, _picker, _query, generation),
    do: empty_ledger_picker(generation)

  defp ledger_picker(posting, picker, query, generation) do
    case ledger_picker_config(posting, picker) do
      nil ->
        empty_ledger_picker(generation)

      config ->
        query = String.trim(to_string(query || ""))

        %{
          status: :open,
          picker: picker,
          trigger_id: config.trigger_id,
          generation: generation,
          title: config.title,
          form: to_form(%{"query" => query}, as: :ledger_picker),
          options: ranked_ledger_options(config.options, query, config.selected_identity),
          selected_identity: config.selected_identity
        }
    end
  end

  defp ledger_picker_config(posting, "party") do
    %{
      kind: :party,
      title: "Tally party ledger",
      trigger_id: "tally_posting_party_ledger_identity",
      options: posting.party_choices,
      selected_identity: posting.form[:party_ledger_identity].value
    }
  end

  defp ledger_picker_config(posting, "sales:" <> index) do
    with {index, ""} <- Integer.parse(index),
         %{} = row <- Enum.find(posting.line_rows, &(&1.index == index)) do
      %{
        kind: {:sales, index},
        title: "Tally sales ledger",
        trigger_id: "tally-posting-line-sales-ledger-#{index}",
        options: posting.sales_choices,
        selected_identity: row.sales_ledger_identity
      }
    else
      _invalid -> nil
    end
  end

  defp ledger_picker_config(posting, "tax:" <> head) when head in ~w(cgst sgst igst) do
    case Enum.find(posting.tax_rows, &(&1.head == head)) do
      nil ->
        nil

      row ->
        %{
          kind: {:tax, row.field},
          title: "#{row.label} ledger",
          trigger_id: "tally_posting_#{row.head}_ledger_identity",
          options: Map.get(posting.tax_choices, row.head, []),
          selected_identity: posting.form[row.field].value
        }
    end
  end

  defp ledger_picker_config(_posting, _picker), do: nil

  defp ranked_ledger_options(options, "", selected_identity) do
    options
    |> Enum.sort_by(fn {label, identity} ->
      {if(identity == selected_identity, do: 0, else: 1), normalize_ledger_search(label)}
    end)
    |> Enum.take(50)
  end

  defp ranked_ledger_options(options, query, _selected_identity) do
    normalized_query = normalize_ledger_search(query)

    options
    |> Enum.filter(fn {label, _identity} ->
      String.contains?(normalize_ledger_search(label), normalized_query)
    end)
    |> Enum.sort_by(fn {label, _identity} -> ledger_match_key(label, normalized_query) end)
    |> Enum.take(50)
  end

  defp ledger_match_key(label, query) do
    normalized = normalize_ledger_search(label)

    strength =
      cond do
        normalized == query ->
          0

        String.starts_with?(normalized, query) ->
          1

        Enum.any?(
          String.split(normalized, ~r/[^\p{L}\p{N}]+/u, trim: true),
          &String.starts_with?(&1, query)
        ) ->
          2

        true ->
          3
      end

    {strength, String.length(normalized), normalized}
  end

  defp normalize_ledger_search(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp choose_ledger(socket, picker, generation, identity) do
    posting = socket.assigns.tally_posting

    with true <- current_ledger_picker?(socket, picker, generation),
         %{} = config <- ledger_picker_config(posting, picker),
         true <-
           Enum.any?(config.options, fn {_label, option_identity} ->
             option_identity == identity
           end) do
      posting = put_ledger_identity(posting, config.kind, identity)

      {:noreply,
       socket
       |> assign(:tally_posting, posting)
       |> assign(
         :ledger_picker,
         empty_ledger_picker(socket.assigns.ledger_picker.generation)
       )}
    else
      _invalid -> {:noreply, socket}
    end
  end

  defp current_ledger_picker?(socket, picker, generation) do
    current = socket.assigns.ledger_picker

    current.status == :open and current.picker == picker and
      Integer.to_string(current.generation) == to_string(generation)
  end

  defp put_ledger_identity(posting, :party, identity) do
    params = Map.put(posting.form.params || %{}, "party_ledger_identity", identity)
    %{posting | form: to_form(params, as: :tally_posting)}
  end

  defp put_ledger_identity(posting, {:sales, index}, identity) do
    identities =
      posting.line_rows
      |> Map.new(&{to_string(&1.index), &1.sales_ledger_identity})
      |> Map.put(to_string(index), identity)

    params = Map.put(posting.form.params || %{}, "line_sales_ledger_identities", identities)

    line_rows =
      Enum.map(posting.line_rows, fn row ->
        if row.index == index, do: %{row | sales_ledger_identity: identity}, else: row
      end)

    %{posting | form: to_form(params, as: :tally_posting), line_rows: line_rows}
  end

  defp put_ledger_identity(posting, {:tax, field}, identity) do
    params = Map.put(posting.form.params || %{}, to_string(field), identity)
    %{posting | form: to_form(params, as: :tally_posting)}
  end

  defp applicable_tax_heads(invoice) do
    ~w(cgst sgst igst)
    |> Enum.filter(fn head ->
      Enum.any?(invoice["line_items"] || [], fn line ->
        positive?(line["#{head}_amount"]) or positive?(line["#{head}_rate"])
      end)
    end)
    |> MapSet.new()
  end

  defp positive?(value) when is_number(value), do: value > 0

  defp positive?(value) when is_binary(value) do
    case Money.decimal_or_error(value) do
      {:ok, decimal} -> Decimal.positive?(decimal)
      _missing_or_unreadable -> false
    end
  end

  defp positive?(_value), do: false

  defp tax_amount(invoice, head) do
    invoice
    |> Map.get("line_items", [])
    |> Enum.reduce(0.0, fn line, total -> total + number(line["#{head}_amount"]) end)
  end

  def tax_posting_label(invoice, head, fallback) do
    rates =
      invoice
      |> Map.get("line_items", [])
      |> Enum.map(&number(&1["#{head}_rate"]))
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()

    case rates do
      [rate] -> "#{fallback} #{working_number(rate)}%"
      _ -> fallback
    end
  end

  def missing_mapping_text(posting) do
    case length(posting_requirements(posting)) do
      0 -> "Complete"
      1 -> "1 required"
      count -> "#{count} required"
    end
  end

  defp valid_ledger_identity?(identity, options) when is_binary(identity) do
    Enum.any?(options, fn {_label, option_identity} -> option_identity == identity end)
  end

  defp valid_ledger_identity?(_identity, _options), do: false

  defp tax_ledger_field("cgst"), do: :cgst_ledger_identity
  defp tax_ledger_field("sgst"), do: :sgst_ledger_identity
  defp tax_ledger_field("igst"), do: :igst_ledger_identity

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value), do: Money.rupee_number(value) || 0.0

  defp number(_value), do: 0.0

  defp line_sales_ledger_identity(%{"line_sales_ledger_identities" => values})
       when is_map(values) do
    identities =
      values
      |> Map.values()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case identities do
      [] -> :none
      [identity] -> {:ok, identity}
      _ -> :mixed
    end
  end

  defp line_sales_ledger_identity(_posting), do: :none

  defp first_line_sales_ledger_identity(%{"line_sales_ledger_identities" => values})
       when is_map(values) do
    Enum.find_value(values, fn {_index, value} ->
      case value do
        identity when is_binary(identity) ->
          identity = String.trim(identity)
          if identity == "", do: nil, else: identity

        _invalid ->
          nil
      end
    end)
  end

  defp first_line_sales_ledger_identity(_posting), do: nil

  defp prepare_packet(dumps, client_id) do
    packet = TallyPacket.prepare(dumps)

    gst_issues =
      dumps
      |> Enum.uniq_by(& &1.period)
      |> Enum.flat_map(fn dump ->
        case Nila.Gst.Sales.Months.get_by_period(dump.org_id, client_id, dump.period) do
          {:ok, month} ->
            Nila.Gst.Sales.Resolutions.workings(month).issues

          _ ->
            packet.source_issues ++
              Nila.Gst.Sales.Gstr1Readiness.issues(packet.all_invoices) ++
              Gstr1.period_issues(packet.all_invoices, dump.period)
        end
      end)
      |> Enum.filter(&(Nila.Gst.Issues.gating?(&1) && &1["status"] != "resolved"))

    packet = Map.put(packet, :gst_issues, gst_issues)
    all_invoices = Enum.map(packet.all_invoices, &attach_image_urls(&1, dumps, client_id))
    invoices_by_id = Map.new(all_invoices, &{Invoice.source_id(&1), &1})

    invoices = Enum.map(packet.invoices, &Map.fetch!(invoices_by_id, Invoice.source_id(&1)))

    attach_reviews = fn reviews ->
      Enum.map(reviews, fn review_case ->
        %{
          review_case
          | invoice: Map.fetch!(invoices_by_id, Invoice.source_id(review_case.invoice))
        }
      end)
    end

    warnings = attach_reviews.(packet.warnings)
    blocked = attach_reviews.(packet.blocked)
    excluded = Enum.map(packet.excluded, &Map.fetch!(invoices_by_id, Invoice.source_id(&1)))

    %{
      packet
      | all_invoices: all_invoices,
        invoices: invoices,
        warnings: warnings,
        blocked: blocked,
        excluded: excluded,
        needs_review: warnings ++ blocked
    }
  end

  defp reload_packet(socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyPacket.fetch(org_id, socket.assigns.client.id, socket.assigns.batch_ref) do
      {:ok, dumps} ->
        packet = prepare_packet(dumps, socket.assigns.client.id)

        socket
        |> assign(:packet, packet)
        |> assign(:source_dumps, dumps)
        |> assign(:send_holds, current_send_holds(org_id, socket.assigns.tally_company, packet))
        |> refresh_required_mapping_invoices()

      {:error, _reason} ->
        socket
    end
  end

  defp reload_processing_result(socket) do
    org_id = socket.assigns.current_scope.current_org.id

    case TallyPacket.fetch(org_id, socket.assigns.client.id, socket.assigns.batch_ref) do
      {:ok, dumps} ->
        socket
        |> assign(:processing_jobs, processing_jobs(dumps))
        |> reload_packet()

      {:error, _reason} ->
        socket
    end
  end

  defp processing_jobs(dumps) do
    Map.new(dumps, fn dump ->
      {dump.id,
       %{
         status: processing_status(dump.status),
         progress: nil,
         bill_count: if(dump.status == "extracted", do: length(dump.invoices), else: nil),
         page_count: Map.get(dump.meta || %{}, "source_page_count"),
         retrying: nil,
         worker_retry: nil
       }}
    end)
  end

  defp processing_status("received"), do: :queued
  defp processing_status("extracting"), do: :extracting
  defp processing_status("extracted"), do: :done
  defp processing_status("failed"), do: :failed
  defp processing_status("held"), do: :held
  defp processing_status("after_filing"), do: :after_filing
  defp processing_status("needs_confirmation"), do: :needs_confirmation
  defp processing_status("discarded"), do: :failed

  defp apply_processing_progress(job, {:done, _client_id, _period, _unaccounted}),
    do: %{job | status: :done, progress: nil, retrying: nil, worker_retry: nil}

  defp apply_processing_progress(job, {:failed, _reason}),
    do: %{job | status: :failed, progress: nil, retrying: nil, worker_retry: nil}

  defp apply_processing_progress(job, {:worker_retrying, attempt, max_attempts}),
    do: %{
      job
      | status: :extracting,
        retrying: nil,
        worker_retry: %{attempt: attempt, max_attempts: max_attempts}
    }

  defp apply_processing_progress(job, :extracting),
    do: %{job | status: :extracting, retrying: nil}

  defp apply_processing_progress(job, {:extracting, progress}) when is_map(progress),
    do: %{
      job
      | status: :extracting,
        progress: progress,
        bill_count: processing_bill_count(progress, job.bill_count),
        page_count: processing_page_count(progress, job.page_count),
        retrying: nil
    }

  defp apply_processing_progress(job, {:extracting_retry, pages}),
    do: %{job | status: :extracting, retrying: pages}

  defp apply_processing_progress(job, status) when is_atom(status),
    do: %{job | status: status, retrying: nil, worker_retry: nil}

  defp processing_bill_count(%{stage: :reading, total: total}, _previous), do: total
  defp processing_bill_count(_progress, previous), do: previous

  defp processing_page_count(%{page_count: count}, _previous) when is_integer(count), do: count
  defp processing_page_count(%{stage: :segmenting, total: total}, _previous), do: total
  defp processing_page_count(_progress, previous), do: previous

  @settled_processing_statuses [:done, :failed, :held, :after_filing, :needs_confirmation]

  def processing?(jobs),
    do: Enum.any?(jobs, fn {_id, job} -> job.status not in @settled_processing_statuses end)

  def processing_invoice_progress(jobs) do
    jobs = jobs |> Map.values() |> Enum.reject(&(&1.status == :failed))

    if jobs != [] and Enum.all?(jobs, &is_integer(&1.bill_count)) do
      total = Enum.sum(Enum.map(jobs, & &1.bill_count))

      done =
        Enum.sum(
          Enum.map(jobs, fn
            %{status: :done, bill_count: count} -> count
            %{progress: %{stage: :reading, done: count}} -> count
            _job -> 0
          end)
        )

      %{done: done, total: total}
    end
  end

  def processing_progress_label(jobs) do
    case processing_invoice_progress(jobs) do
      %{done: done, total: total} -> "#{done} of #{total} read"
      nil -> "Finding invoices…"
    end
  end

  def processing_source_label(jobs) do
    jobs = Map.values(jobs)

    if jobs != [] and Enum.all?(jobs, &is_integer(&1.page_count)) do
      pages = Enum.sum(Enum.map(jobs, & &1.page_count))
      "#{pages} #{plural(pages, "page")} uploaded"
    else
      files = length(jobs)
      "#{files} #{plural(files, "file")} uploaded"
    end
  end

  def processing_retry_label(jobs) do
    cond do
      Enum.any?(jobs, fn {_id, job} -> job.worker_retry end) ->
        "Processing was interrupted. Nila is trying again."

      Enum.any?(jobs, fn {_id, job} -> job.retrying end) ->
        "One read took longer. Nila is asking again."

      true ->
        nil
    end
  end

  defp find_packet_invoice(packet, source_id, fallback) do
    Enum.find(packet.all_invoices, &(Invoice.source_id(&1) == source_id)) || fallback
  end

  defp attach_image_urls(invoice, dumps, client_id) do
    images = List.wrap(invoice["images"] || invoice["image"])

    urls =
      Enum.flat_map(images, fn image ->
        case dump_for_image(dumps, image) do
          nil ->
            []

          dump ->
            [
              "/sales-bills/#{client_id}/dumps/#{dump.id}/evidence/#{Path.basename(image)}"
            ]
        end
      end)

    Map.put(invoice, "image_urls", urls)
  end

  defp dump_for_image(dumps, image) when is_binary(image) do
    case Regex.run(~r/^d(\d+)_/, Path.basename(image)) do
      [_, id] -> Enum.find(dumps, &(Integer.to_string(&1.id) == id))
      _ -> List.first(dumps)
    end
  end

  defp dump_for_image(_dumps, _image), do: nil

  def invoice_id(nil), do: nil
  def invoice_id(invoice), do: invoice["id"] || invoice["invoice_number"]

  defp posting_navigation(invoices, invoice) do
    case Enum.find_index(invoices, &(invoice_id(&1) == invoice_id(invoice))) do
      nil ->
        %{previous: nil, next: nil, position: 0, total: length(invoices)}

      index ->
        %{
          previous: if(index > 0, do: Enum.at(invoices, index - 1)),
          next: Enum.at(invoices, index + 1),
          position: index + 1,
          total: length(invoices)
        }
    end
  end

  def narration(invoice),
    do: invoice["narration"] || invoice["remarks"] || invoice["notes"] || "Imported from Nila"

  defp sending_to_tally?(jobs), do: Enum.any?(jobs, &(&1.status in ["pending", "running"]))

  def tally_result([], _expected_count), do: nil

  def tally_result(jobs, expected_count) do
    added = Enum.count(jobs, &(&1.status == "succeeded"))
    finished = Enum.count(jobs, &(&1.status in ["succeeded", "failed", "indeterminate"]))

    cond do
      sending_to_tally?(jobs) -> :sending
      added == expected_count and length(jobs) == expected_count -> :added
      finished == length(jobs) -> {:partial, added, expected_count}
      true -> :sending
    end
  end

  def selected_tally_job(_jobs, nil, _all_invoices), do: nil

  def selected_tally_job(jobs, invoice, all_invoices) do
    source_id = Invoice.source_id(invoice)
    invoice_number = invoice["invoice_number"]

    Enum.find(jobs, &(&1.payload["invoice_source_id"] == source_id)) ||
      if unique_invoice_number?(all_invoices, invoice_number) do
        Enum.find(jobs, fn job ->
          is_nil(job.payload["invoice_source_id"]) and
            job.payload["invoice_number"] == invoice_number
        end)
      end
  end

  defp unique_invoice_number?(nil, _invoice_number), do: true

  defp unique_invoice_number?(invoices, invoice_number) do
    Enum.count(invoices, &(&1["invoice_number"] == invoice_number)) == 1
  end

  def invoice_frozen?(_jobs, nil, _all_invoices), do: false

  def invoice_frozen?(jobs, invoice, all_invoices),
    do: not is_nil(selected_tally_job(jobs, invoice, all_invoices))

  defp invoice_frozen_now?(socket, invoice) do
    org_id = socket.assigns.current_scope.current_org.id

    org_id
    |> list_tally_jobs(socket.assigns.sales_batch)
    |> invoice_frozen?(invoice, socket.assigns.packet.all_invoices)
  end

  def selected_delivery_state(nil), do: nil

  def selected_delivery_state(%{status: status}) when status in ["pending", "running"],
    do: :sending

  def selected_delivery_state(%{status: "succeeded"}), do: :added
  def selected_delivery_state(%{status: "indeterminate"}), do: :unknown
  def selected_delivery_state(%{status: "failed"}), do: :failed

  def invoice_delivery(invoice, jobs, packet, send_holds, required_mapping_invoices) do
    case selected_delivery_state(selected_tally_job(jobs, invoice, packet.all_invoices)) do
      :sending -> %{label: "Adding…", variant: "info"}
      :added -> %{label: "Added", variant: "success"}
      :unknown -> %{label: "Check in Tally", variant: "warning"}
      :failed -> %{label: "Couldn't add", variant: "error"}
      nil -> invoice_readiness_delivery(packet, invoice, send_holds, required_mapping_invoices)
    end
  end

  defp invoice_readiness_delivery(packet, invoice, send_holds, required_mapping_invoices) do
    cond do
      Enum.any?(packet.excluded, &(Invoice.source_id(&1) == Invoice.source_id(invoice))) ->
        %{label: "Excluded", variant: "neutral"}

      Map.get(send_holds, Invoice.source_id(invoice)) == :cannot_send ->
        %{label: "Cannot send", variant: "error"}

      invoice_case(packet.blocked, invoice) ->
        %{label: "Cannot send", variant: "error"}

      review_case = invoice_case(packet.warnings, invoice) ->
        %{
          label: if(tax_review_case?(review_case), do: "Tax review", else: "Review needed"),
          variant: "warning"
        }

      required_mapping_invoice?(required_mapping_invoices, invoice) ->
        %{label: "Mapping needed", variant: "warning"}

      Map.get(send_holds, Invoice.source_id(invoice)) == :needs_review ->
        %{label: "Review needed", variant: "warning"}

      true ->
        %{label: "Ready", variant: "neutral"}
    end
  end

  def retryable?(jobs),
    do:
      Enum.any?(jobs, &(&1.status == "failed")) and
        Enum.all?(jobs, &(&1.status != "indeterminate"))

  def verifiable?(jobs), do: Enum.any?(jobs, &(&1.status == "indeterminate"))

  def missing_delivery_jobs?(packet, jobs), do: length(jobs) < length(packet.invoices)

  def review_reason(review_case), do: review_presentation(review_case).summary

  defp tax_review_case?(review_case) do
    review_case
    |> review_presentation()
    |> Map.fetch!(:items)
    |> Enum.any?(
      &(&1.topic in ["tax treatment", "place of supply", "tax calculations", "GST rates"])
    )
  end

  def invoice_attention_reason(
        packet,
        required_mapping_invoices,
        required_mapping_counts,
        invoice
      ) do
    case invoice_case(packet.needs_review, invoice) do
      nil ->
        if required_mapping_invoice?(required_mapping_invoices, invoice) do
          case Map.get(required_mapping_counts, Invoice.source_id(invoice)) do
            1 -> "1 ledger missing"
            count when is_integer(count) -> "#{count} ledgers missing"
            _unknown -> "Tally mappings needed"
          end
        end

      review_case ->
        review_case
        |> review_presentation()
        |> Map.fetch!(:items)
        |> case do
          [%{queue_detail: detail}] -> detail
          _items -> review_reason(review_case)
        end
    end
  end

  defp selected_review(_packet, nil), do: nil

  defp selected_review(packet, invoice) do
    case invoice_case(packet.needs_review, invoice) do
      nil -> nil
      review_case -> review_presentation(review_case)
    end
  end

  def review_items(nil, _target), do: []
  def review_items(review, target), do: Enum.filter(review.items, &(&1.target == target))

  def missing_amount_issue(assigns) do
    Enum.find(gst_workbench_issues(assigns), &(&1["code"] == "missing_taxable_value"))
  end

  def other_gst_workbench_issues(assigns) do
    Enum.reject(gst_workbench_issues(assigns), &(&1["code"] == "missing_taxable_value"))
  end

  def line_missing_hsn_issue(assigns) do
    Enum.find(gst_workbench_issues(assigns), fn issue ->
      issue["code"] == "missing_hsn_sac" and
        (assigns.editing_line_index + 1) in issue["lines"]
    end)
  end

  def missing_amount_title(issue) do
    case length(issue["lines"]) do
      1 -> "Taxable amount missing on 1 line"
      count -> "Taxable amounts missing on #{count} lines"
    end
  end

  def gst_workbench_issues(%{workbench_context: %{item: item}}) do
    Enum.filter(item.actionable_issues, &(&1["status"] == "open"))
  end

  def gst_workbench_issues(assigns) do
    Enum.filter(assigns.packet.gst_issues, fn issue ->
      issue["source_id"] == invoice_id(assigns.selected_invoice) && Nila.Gst.Issues.gating?(issue)
    end)
  end

  def batch_gst_issues(packet, invoice) do
    if excluded_invoice?(packet, invoice) do
      []
    else
      Enum.filter(packet.gst_issues, fn issue ->
        issue["source_id"] == Invoice.source_id(invoice) ||
          Invoice.source_id(invoice) in List.wrap(issue["source_ids"]) ||
          (is_nil(issue["source_id"]) && issue["invoice_number"] == invoice["invoice_number"])
      end)
    end
  end

  def batch_gst_review_invoices(packet),
    do: Enum.filter(packet.all_invoices, &(batch_gst_issues(packet, &1) != []))

  def review_line_items(nil, _index), do: []

  def review_line_items(review, index) do
    line_number = index + 1
    Enum.filter(review.items, &(&1.target == :lines and line_number in &1.lines))
  end

  def review_item_copy(%{detail: detail}) when is_binary(detail), do: detail
  def review_item_copy(_item), do: "Review this value before saving."

  def next_review_item(review), do: List.first(review.items)

  def review_item_target(%{target: :allocations}), do: "#sales-bill-review-allocation-0"

  def review_item_target(%{target: :lines, lines: [line | _]}),
    do: "#sales-bill-posting-line-#{line - 1}"

  def review_item_target(%{target: :facts}), do: "#sales-bill-edit-invoice-facts"
  def review_item_target(_item), do: "#sales-bill-review-global-0"

  def review_item_focus(%{codes: codes}) do
    cond do
      Enum.any?(codes, &(&1 in ~w(unreadable_invoice_date))) ->
        "invoice_date"

      Enum.any?(
        codes,
        &(&1 in ~w(missing_invoice_number implausible_invoice_number duplicate_invoice_number))
      ) ->
        "invoice_number"

      Enum.any?(
        codes,
        &(&1 in ~w(invalid_gstin recipient_registration_conflict unknown_recipient_registration))
      ) ->
        "buyer_gstin"

      true ->
        "invoice_number"
    end
  end

  defp invoice_case(_cases, nil), do: nil

  defp invoice_case(cases, invoice) do
    source_id = Invoice.source_id(invoice)
    Enum.find(cases, &(Invoice.source_id(&1.invoice) == source_id))
  end

  defp review_presentation(%{invoice: invoice, issues: issues}),
    do: SalesIssuePresentation.for_invoice(invoice, issues)

  def remainder_title(packet, jobs, send_holds) do
    if Enum.any?(jobs, &(&1.status in ["failed", "indeterminate"])) or
         map_size(send_holds) > 0 or (jobs != [] and missing_delivery_jobs?(packet, jobs)),
       do: "Not added to Tally",
       else: "Not included"
  end

  def tally_master_sync_instruction(assigns) do
    cond do
      not assigns.tally_device_online? ->
        "Open #{assigns.tally_company.name} in TallyPrime, start Nila Connector, and sync once so Nila can use its ledgers."

      not assigns.tally_company_open? ->
        "Open #{assigns.tally_company.name} in TallyPrime and sync once so Nila can use its ledgers."

      true ->
        "Sync #{assigns.tally_company.name} once so Nila can use its ledgers."
    end
  end

  def format_master_sync(nil), do: "previously"

  def format_master_sync(datetime),
    do: Nila.Formatters.format_display_datetime_with_time(datetime)
end
