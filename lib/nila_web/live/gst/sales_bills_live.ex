defmodule NilaWeb.Gst.SalesBillsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Money
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.{Batch, Gstr1, Invoice, InvoiceCorrections, InvoiceRemovals, TallyPacket}
  alias Nila.{TallyDevices, TallyJobs, TallyMappings}
  alias NilaWeb.Gst.SalesIssuePresentation
  alias NilaWeb.Presence

  @impl true
  def mount(%{"client_id" => client_id, "batch_ref" => batch_ref}, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    if connected?(socket), do: ClientMonths.subscribe(org_id)

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, batch, dumps} <- TallyPacket.fetch_with_record(org_id, client_id, batch_ref) do
      if connected?(socket) do
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

  @impl true
  def handle_params(params, _uri, socket) do
    previous_id = invoice_id(socket.assigns.selected_invoice)
    review_mode? = params["review"] == "required"

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

    selected_review = selected_review(socket.assigns.packet, invoice)

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
     |> assign(:ledger_picker, empty_ledger_picker())
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
     )}
  end

  defp totals(invoice), do: Invoice.extracted_totals(invoice)

  defp invoice_total(invoice) do
    amounts = totals(invoice)

    if is_number(amounts.taxable) and is_number(amounts.tax),
      do: amounts.taxable + amounts.tax
  end

  defp printed_total(invoice), do: invoice["printed_grand_total"]

  defp total_mismatch?(invoice) do
    totals = Invoice.extracted_totals_paise(invoice)

    case {totals.taxable_paise, Money.paise_or_error(printed_total(invoice))} do
      {taxable_paise, {:ok, printed_paise}} when is_integer(taxable_paise) ->
        abs(taxable_paise + totals.tax_paise - printed_paise) > 1

      _incomplete ->
        false
    end
  end

  defp rupees(value) do
    case Money.paise_or_error(value) do
      {:ok, paise} -> Nila.Formatters.format_money_with_paise(paise)
      _missing_or_unreadable -> "—"
    end
  end

  defp working_number(value) when is_integer(value), do: Integer.to_string(value)

  defp working_number(value) when is_float(value) do
    if value == trunc(value), do: Integer.to_string(trunc(value)), else: Float.to_string(value)
  end

  defp working_number(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: "—", else: value
  end

  defp working_number(_value), do: "—"

  defp money(paise), do: Nila.Formatters.format_money_with_paise(paise)

  @impl true
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
    {:noreply,
     push_patch(socket,
       to: ~p"/sales-bills/#{socket.assigns.client.id}/batch/#{socket.assigns.batch_ref}"
     )}
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
            {:noreply, reload_packet(socket)}

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

  def handle_event("navigate-posting-review", %{"item" => source_id}, socket) do
    case Enum.find(socket.assigns.packet.all_invoices, &(invoice_id(&1) == source_id)) do
      nil ->
        {:noreply, socket}

      invoice ->
        {:noreply,
         push_patch(socket,
           to:
             posting_review_path(
               socket.assigns.client,
               socket.assigns.batch_ref,
               invoice,
               socket.assigns.review_mode?
             )
         )}
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
    {:noreply,
     assign(socket, :ledger_picker, ledger_picker(socket.assigns.tally_posting, picker, ""))}
  end

  def handle_event(
        "filter-ledger-picker",
        %{"ledger_picker" => %{"query" => query}},
        socket
      ) do
    picker = socket.assigns.ledger_picker.picker

    {:noreply,
     assign(socket, :ledger_picker, ledger_picker(socket.assigns.tally_posting, picker, query))}
  end

  def handle_event(
        "choose-first-ledger",
        %{"ledger_picker" => %{"query" => query}},
        socket
      ) do
    picker = socket.assigns.ledger_picker.picker

    case ledger_picker(socket.assigns.tally_posting, picker, query).options do
      [{_label, identity} | _rest] -> choose_ledger(socket, picker, identity)
      [] -> {:noreply, socket}
    end
  end

  def handle_event("choose-ledger", %{"identity" => identity}, socket) do
    choose_ledger(socket, socket.assigns.ledger_picker.picker, identity)
  end

  def handle_event("close-ledger-picker", _params, socket) do
    {:noreply, assign(socket, :ledger_picker, empty_ledger_picker())}
  end

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
              true
            )

          _finished_or_direct ->
            ~p"/sales-bills/#{socket.assigns.client.id}/batch/#{socket.assigns.batch_ref}"
        end

      {:noreply,
       socket
       |> put_flash(:info, "Tally posting saved.")
       |> push_patch(to: destination)}
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
    |> assign(:selected_review, selected_review(socket.assigns.packet, corrected_invoice))
    |> assign(:posting_preview_invoice, corrected_invoice)
    |> assign(
      :posting_navigation,
      posting_navigation(socket.assigns.packet.all_invoices, corrected_invoice)
    )
    |> assign(:tally_posting, tally_posting(socket.assigns, corrected_invoice))
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
    |> assign(:selected_review, selected_review(socket.assigns.packet, corrected_invoice))
    |> assign(:posting_preview_invoice, preview_invoice)
    |> assign(
      :posting_navigation,
      posting_navigation(socket.assigns.packet.all_invoices, corrected_invoice)
    )
    |> assign(:tally_posting, tally_posting)
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
      Enum.reduce(row.tax_rows, values, fn tax, current ->
        current
        |> Map.put("#{tax.head}_rate", tax.rate)
        |> Map.put("#{tax.head}_amount", tax.amount)
      end)
    end)
  end

  defp invoice_facts_values(invoice) do
    Map.take(
      invoice || %{},
      ~w(invoice_number invoice_date buyer_name buyer_gstin)
    )
  end

  defp tax_edit_field("cgst", :rate), do: :cgst_rate
  defp tax_edit_field("cgst", :amount), do: :cgst_amount
  defp tax_edit_field("sgst", :rate), do: :sgst_rate
  defp tax_edit_field("sgst", :amount), do: :sgst_amount
  defp tax_edit_field("igst", :rate), do: :igst_rate
  defp tax_edit_field("igst", :amount), do: :igst_amount

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

  defp voucher_numbering_error(issues) do
    types = issues |> Enum.map(& &1.voucher_type) |> Enum.uniq() |> Enum.join(", ")

    "#{types} voucher numbering in Tally must be Manual or Automatic (Manual Override). Change it in Tally, sync the company, then retry."
  end

  @impl true
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

  defp remainder(packet, tally_jobs) do
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

  defp plural(1, singular), do: singular
  defp plural(_count, singular), do: singular <> "s"

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

  defp posting_review_path(client, batch_ref, invoice, review_mode? \\ false) do
    params = %{"item" => invoice["id"] || invoice["invoice_number"]}
    params = if review_mode?, do: Map.put(params, "review", "required"), else: params
    "/sales-bills/#{client.id}/batch/#{batch_ref}?#{URI.encode_query(params)}"
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
      party_choices: ledger_options(choices, "Sundry Debtors"),
      sales_choices: ledger_options(choices, "Sales Accounts"),
      tax_choices: ledger_options(choices, "Duties & Taxes"),
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

  defp posting_requirements(nil), do: []

  defp posting_requirements(posting) do
    party =
      if blank_identity?(posting.form[:party_ledger_identity].value) do
        [
          %{
            key: :party_ledger,
            label: "Choose the Tally party ledger",
            trigger_id: "tally_posting_party_ledger_identity"
          }
        ]
      else
        []
      end

    sales =
      posting.line_rows
      |> Enum.filter(&blank_identity?(&1.sales_ledger_identity))
      |> Enum.map(fn row ->
        description = row.line["description"] || row.line["item_name"] || "unnamed line"

        %{
          key: {:sales_ledger, row.index},
          label: "Choose the sales ledger for “#{description}”",
          trigger_id: "tally-posting-line-sales-ledger-#{row.index}"
        }
      end)

    tax =
      posting.tax_rows
      |> Enum.filter(&blank_identity?(posting.form[&1.field].value))
      |> Enum.map(fn row ->
        %{
          key: {:tax_ledger, row.head},
          label: "Choose the #{row.label} ledger",
          trigger_id: "tally_posting_#{row.head}_ledger_identity"
        }
      end)

    party ++ sales ++ tax
  end

  defp next_posting_requirement(posting), do: List.first(posting_requirements(posting))

  defp ready_invoice_count(packet, required_mapping_invoices) do
    max(
      length(packet.invoices) - length(attention_invoices(packet, required_mapping_invoices)),
      0
    )
  end

  defp attention_invoices(packet, required_mapping_invoices) do
    attention_ids =
      packet.needs_review
      |> Enum.map(&Invoice.source_id(&1.invoice))
      |> Kernel.++(Enum.map(required_mapping_invoices, &Invoice.source_id/1))
      |> MapSet.new()

    Enum.filter(packet.invoices, &(Invoice.source_id(&1) in attention_ids))
  end

  defp attention_invoice_count(packet, required_mapping_invoices) do
    packet.needs_review
    |> Enum.map(&Invoice.source_id(&1.invoice))
    |> Kernel.++(Enum.map(required_mapping_invoices, &Invoice.source_id/1))
    |> Enum.uniq()
    |> length()
  end

  defp batch_result_title(packet, required_mapping_invoices) do
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

  defp attention_summary(packet, required_mapping_invoices) do
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

  defp excluded_summary(%{excluded: []}), do: nil
  defp excluded_summary(packet), do: "#{length(packet.excluded)} excluded"

  defp batch_table_invoices(packet) do
    Enum.reject(packet.all_invoices, &excluded_invoice?(packet, &1)) ++ packet.excluded
  end

  defp excluded_invoice?(packet, invoice) do
    Enum.any?(packet.excluded, &(Invoice.source_id(&1) == Invoice.source_id(invoice)))
  end

  defp batch_row_path(packet, client, batch_ref, invoice) do
    if excluded_invoice?(packet, invoice),
      do: nil,
      else: posting_review_path(client, batch_ref, invoice)
  end

  defp batch_row_class(packet, invoice) do
    if excluded_invoice?(packet, invoice), do: "bg-base-200/40 text-ink-muted"
  end

  defp ready_totals(packet, required_mapping_invoices) do
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

  defp ledger_options(choices, parent) do
    matching = Enum.filter(choices, &(normalized_parent(&1) == String.downcase(parent)))
    choices = if matching == [], do: choices, else: matching
    Enum.map(choices, &{&1.name, &1.identity})
  end

  defp empty_ledger_picker do
    %{
      picker: nil,
      title: "Choose ledger",
      form: to_form(%{"query" => ""}, as: :ledger_picker),
      options: [],
      selected_identity: nil
    }
  end

  defp ledger_picker(nil, _picker, _query), do: empty_ledger_picker()

  defp ledger_picker(posting, picker, query) do
    case ledger_picker_config(posting, picker) do
      nil ->
        empty_ledger_picker()

      config ->
        query = String.trim(to_string(query || ""))

        %{
          picker: picker,
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
          options: posting.tax_choices,
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

  defp choose_ledger(socket, picker, identity) do
    posting = socket.assigns.tally_posting

    with %{} = config <- ledger_picker_config(posting, picker),
         true <-
           Enum.any?(config.options, fn {_label, option_identity} ->
             option_identity == identity
           end) do
      posting = put_ledger_identity(posting, config.kind, identity)

      {:noreply,
       socket
       |> assign(:tally_posting, posting)
       |> assign(:ledger_picker, empty_ledger_picker())}
    else
      _invalid -> {:noreply, socket}
    end
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

  defp normalized_parent(%{data: data}) when is_map(data) do
    data
    |> Map.get("parent", "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
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

  defp tax_posting_label(invoice, head, fallback) do
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

  defp missing_mapping_text(posting) do
    identities =
      [posting.form[:party_ledger_identity].value] ++
        Enum.map(posting.line_rows, & &1.sales_ledger_identity) ++
        Enum.map(posting.tax_rows, fn row -> posting.form[row.field].value end)

    case Enum.count(identities, &blank_identity?/1) do
      0 -> "Complete"
      1 -> "1 required"
      count -> "#{count} required"
    end
  end

  defp blank_identity?(nil), do: true
  defp blank_identity?(identity) when is_binary(identity), do: String.trim(identity) == ""
  defp blank_identity?(_identity), do: false

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

  defp processing?(jobs),
    do: Enum.any?(jobs, fn {_id, job} -> job.status not in @settled_processing_statuses end)

  defp processing_invoice_progress(jobs) do
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

  defp processing_progress_label(jobs) do
    case processing_invoice_progress(jobs) do
      %{done: done, total: total} -> "#{done} of #{total} read"
      nil -> "Finding invoices…"
    end
  end

  defp processing_source_label(jobs) do
    jobs = Map.values(jobs)

    if jobs != [] and Enum.all?(jobs, &is_integer(&1.page_count)) do
      pages = Enum.sum(Enum.map(jobs, & &1.page_count))
      "#{pages} #{plural(pages, "page")} uploaded"
    else
      files = length(jobs)
      "#{files} #{plural(files, "file")} uploaded"
    end
  end

  defp processing_retry_label(jobs) do
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

  defp invoice_id(nil), do: nil
  defp invoice_id(invoice), do: invoice["id"] || invoice["invoice_number"]

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

  defp narration(invoice),
    do: invoice["narration"] || invoice["remarks"] || invoice["notes"] || "Imported from Nila"

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

  defp selected_tally_job(_jobs, nil, _all_invoices), do: nil

  defp selected_tally_job(jobs, invoice, all_invoices) do
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

  defp invoice_frozen?(_jobs, nil, _all_invoices), do: false

  defp invoice_frozen?(jobs, invoice, all_invoices),
    do: not is_nil(selected_tally_job(jobs, invoice, all_invoices))

  defp invoice_frozen_now?(socket, invoice) do
    org_id = socket.assigns.current_scope.current_org.id

    org_id
    |> list_tally_jobs(socket.assigns.sales_batch)
    |> invoice_frozen?(invoice, socket.assigns.packet.all_invoices)
  end

  defp selected_delivery_state(nil), do: nil

  defp selected_delivery_state(%{status: status}) when status in ["pending", "running"],
    do: :sending

  defp selected_delivery_state(%{status: "succeeded"}), do: :added
  defp selected_delivery_state(%{status: "indeterminate"}), do: :unknown
  defp selected_delivery_state(%{status: "failed"}), do: :failed

  defp invoice_delivery(invoice, jobs, packet, send_holds, required_mapping_invoices) do
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

  defp retryable?(jobs),
    do:
      Enum.any?(jobs, &(&1.status == "failed")) and
        Enum.all?(jobs, &(&1.status != "indeterminate"))

  defp verifiable?(jobs), do: Enum.any?(jobs, &(&1.status == "indeterminate"))

  defp missing_delivery_jobs?(packet, jobs), do: length(jobs) < length(packet.invoices)

  defp review_reason(review_case), do: review_presentation(review_case).summary

  defp tax_review_case?(review_case) do
    review_case
    |> review_presentation()
    |> Map.fetch!(:items)
    |> Enum.any?(
      &(&1.topic in ["tax treatment", "place of supply", "tax calculations", "GST rates"])
    )
  end

  defp invoice_attention_reason(
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

  defp review_items(nil, _target), do: []
  defp review_items(review, target), do: Enum.filter(review.items, &(&1.target == target))

  defp review_line_items(nil, _index), do: []

  defp review_line_items(review, index) do
    line_number = index + 1
    Enum.filter(review.items, &(&1.target == :lines and line_number in &1.lines))
  end

  defp review_item_copy(%{detail: detail}) when is_binary(detail), do: detail
  defp review_item_copy(_item), do: "Review this value before saving."

  defp next_review_item(review), do: List.first(review.items)

  defp review_item_target(%{target: :allocations}), do: "#sales-bill-review-allocation-0"

  defp review_item_target(%{target: :lines, lines: [line | _]}),
    do: "#sales-bill-posting-line-#{line - 1}"

  defp review_item_target(%{target: :facts}), do: "#sales-bill-edit-invoice-facts"
  defp review_item_target(_item), do: "#sales-bill-review-global-0"

  defp review_item_focus(%{codes: codes}) do
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

  defp remainder_title(packet, jobs, send_holds) do
    if Enum.any?(jobs, &(&1.status in ["failed", "indeterminate"])) or
         map_size(send_holds) > 0 or (jobs != [] and missing_delivery_jobs?(packet, jobs)),
       do: "Not added to Tally",
       else: "Not included"
  end

  defp tally_master_sync_instruction(assigns) do
    cond do
      not assigns.tally_device_online? ->
        "Open #{assigns.tally_company.name} in TallyPrime, start Nila Connector, and sync once so Nila can use its ledgers."

      not assigns.tally_company_open? ->
        "Open #{assigns.tally_company.name} in TallyPrime and sync once so Nila can use its ledgers."

      true ->
        "Sync #{assigns.tally_company.name} once so Nila can use its ledgers."
    end
  end

  defp format_master_sync(nil), do: "previously"

  defp format_master_sync(datetime),
    do: Nila.Formatters.format_display_datetime_with_time(datetime)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={assigns[:current_path]}
      active_client={@client}
    >
      <div id="sales-bills-result" class="space-y-region mx-auto max-w-6xl">
        <.link
          navigate={~p"/sales-bills"}
          id="sales-bills-back"
          class="text-ink-muted text-ui inline-flex items-center gap-1 font-medium"
        >
          <.icon name="hero-arrow-left-mini" class="size-4" /> Sales bills
        </.link>

        <section :if={processing?(@processing_jobs)} id="sales-bills-processing">
          <div class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>
            <h1 class="text-base-content text-h2 font-semibold">
              Reading invoices
            </h1>
            <p class="text-ink-muted text-ui tabular-nums">
              {processing_source_label(@processing_jobs)}
            </p>
          </div>

          <div class="mt-section space-y-related max-w-2xl">
            <p
              id="sales-bills-processing-progress"
              class="text-base-content text-h4 font-semibold tabular-nums"
            >
              {processing_progress_label(@processing_jobs)}
            </p>
            <%= if progress = processing_invoice_progress(@processing_jobs) do %>
              <.progress_bar
                id="sales-bills-processing-bar"
                value={progress.done}
                max={max(progress.total, 1)}
              />
            <% end %>
            <p
              :if={processing_retry_label(@processing_jobs)}
              id="sales-bills-processing-retry"
              class="text-ui text-warning"
            >
              {processing_retry_label(@processing_jobs)}
            </p>
            <p class="text-ink-muted text-ui">
              You can leave this page — processing will continue.
            </p>
          </div>
        </section>

        <section
          :if={not processing?(@processing_jobs)}
          class="gap-region flex flex-col lg:flex-row lg:items-end lg:justify-between"
        >
          <div class="space-y-related">
            <p class="text-ink-muted text-ui">{@client.name}</p>

            <h1 class="text-base-content text-h2 font-semibold">
              {batch_result_title(@packet, @required_mapping_invoices)}
            </h1>

            <p
              :if={
                ready_invoice_count(@packet, @required_mapping_invoices) == 0 and
                  (attention_invoice_count(@packet, @required_mapping_invoices) > 0 or
                     @packet.excluded != [])
              }
              class="text-body text-ink-muted tabular-nums"
            >
              {attention_summary(@packet, @required_mapping_invoices)}
            </p>

            <p
              :if={ready_invoice_count(@packet, @required_mapping_invoices) > 0}
              class="text-ink-muted text-lead tabular-nums"
            >
              {money(ready_totals(@packet, @required_mapping_invoices).taxable_paise)} taxable · {money(
                ready_totals(@packet, @required_mapping_invoices).tax_paise
              )} tax<span :if={@packet.excluded != []}> · {excluded_summary(@packet)}</span>
            </p>
          </div>

          <div
            :if={(@packet.invoices != [] and @tally_company) && @tally_jobs == []}
            id="sales-bills-tally-destination"
            class="flex items-end gap-3"
          >
            <p class="text-ink-muted text-ui pb-2">
              Tally · <span class="text-base-content font-semibold">{@tally_company.name}</span>
            </p>

            <.button
              :if={attention_invoice_count(@packet, @required_mapping_invoices) > 0}
              id="sales-bills-review-required"
              variant={
                if(ready_invoice_count(@packet, @required_mapping_invoices) > 0,
                  do: "outline",
                  else: "primary"
                )
              }
              patch={
                posting_review_path(
                  @client,
                  @batch_ref,
                  List.first(attention_invoices(@packet, @required_mapping_invoices)),
                  true
                )
              }
            >
              Review {attention_invoice_count(@packet, @required_mapping_invoices)}
            </.button>

            <.button
              :if={
                ready_invoice_count(@packet, @required_mapping_invoices) > 0 or
                  @required_mapping_invoices == []
              }
              type="button"
              id="sales-bills-send-to-tally"
              phx-click="request-send-to-tally"
              disabled={not @tally_online? or not @tally_masters_available?}
            >
              Send to Tally
            </.button>
          </div>

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
              phx-click="request-send-to-tally"
              variant="outline"
              disabled={not @tally_online? or not @tally_masters_available?}
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
          :if={not processing?(@processing_jobs) and @packet.failed_files != []}
          id="sales-bills-failed-files"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">Couldn't read</h2>

          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li
              :for={dump <- @packet.failed_files}
              id={"sales-bills-failed-file-#{dump.id}"}
              class="gap-block flex items-center justify-between py-3"
            >
              <span class="text-base-content text-ui font-medium">
                {TallyPacket.original_name(dump)}
              </span>
              <.button
                type="button"
                id={"sales-bills-retry-file-#{dump.id}"}
                phx-click="retry-failed-file"
                phx-value-dump-id={dump.id}
                variant="outline"
              >
                Try again
              </.button>
            </li>
          </ul>
        </section>

        <section
          :if={not processing?(@processing_jobs) and remainder(@packet, @tally_jobs) != []}
          id="sales-bills-remainder"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">
            {remainder_title(@packet, @tally_jobs, @send_holds)}
          </h2>

          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li
              :for={item <- remainder(@packet, @tally_jobs)}
              class="text-base-content text-ui py-3 font-medium"
            >
              {item}
            </li>
          </ul>
        </section>

        <section :if={@packet.all_invoices != []} id="sales-bills-vouchers">
          <.data_table
            id="sales-bills-voucher-table"
            rows={batch_table_invoices(@packet)}
            row_id={fn invoice -> "sales-bill-#{invoice["id"] || invoice["invoice_number"]}" end}
            row_navigate={fn invoice -> batch_row_path(@packet, @client, @batch_ref, invoice) end}
            row_class={fn invoice -> batch_row_class(@packet, invoice) end}
            row_label={
              fn invoice ->
                "Review invoice #{invoice["invoice_number"] || "without a number"}"
              end
            }
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

            <:col :let={invoice} label="Status">
              <span id={"sales-bill-delivery-#{invoice_id(invoice)}"} class="whitespace-nowrap">
                <.badge variant={
                  invoice_delivery(
                    invoice,
                    @tally_jobs,
                    @packet,
                    @send_holds,
                    @required_mapping_invoices
                  ).variant
                }>
                  {invoice_delivery(
                    invoice,
                    @tally_jobs,
                    @packet,
                    @send_holds,
                    @required_mapping_invoices
                  ).label}
                </.badge>
              </span>
              <p
                :if={
                  invoice_attention_reason(
                    @packet,
                    @required_mapping_invoices,
                    @required_mapping_counts,
                    invoice
                  )
                }
                id={"sales-bill-attention-#{invoice_id(invoice)}"}
                class="text-ink-muted text-ui mt-1 max-w-64 whitespace-normal"
              >
                {invoice_attention_reason(
                  @packet,
                  @required_mapping_invoices,
                  @required_mapping_counts,
                  invoice
                )}
              </p>
            </:col>

            <:col :let={invoice} label="" align="right">
              <.action_menu
                :if={not invoice_frozen?(@tally_jobs, invoice, @packet.all_invoices)}
                id={"sales-bill-actions-#{invoice_id(invoice)}"}
                label={"Actions for invoice #{invoice["invoice_number"] || "without a number"}"}
              >
                <:item
                  :if={not Enum.member?(@packet.excluded, invoice)}
                  id={"sales-bill-remove-#{invoice_id(invoice)}"}
                  label="Exclude from batch"
                  icon="hero-minus-circle"
                  on_click="remove-invoice"
                  value={invoice_id(invoice)}
                />
                <:item
                  :if={Enum.member?(@packet.excluded, invoice)}
                  id={"sales-bill-restore-#{invoice_id(invoice)}"}
                  label="Include in batch"
                  icon="hero-arrow-uturn-left"
                  on_click="restore-invoice"
                  value={invoice_id(invoice)}
                />
              </.action_menu>
            </:col>
          </.data_table>
        </section>
      </div>

      <.modal
        :if={@confirming_tally_send}
        id="sales-bills-tally-warning-dialog"
        title={
          "#{length(@packet.warnings)} #{plural(length(@packet.warnings), "invoice")} still #{if(length(@packet.warnings) == 1, do: "needs", else: "need")} review"
        }
        on_close="cancel-send-to-tally"
        return_focus="#sales-bills-send-to-tally, #sales-bills-retry-tally"
      >
        <ul class="border-base-300 divide-base-300 divide-y border-y">
          <li :for={warning <- @packet.warnings} class="space-y-related py-3">
            <p class="text-base-content text-ui font-mono font-medium">
              {warning.invoice["invoice_number"] || "Unnumbered invoice"}
            </p>
            <p class="text-ink-muted text-ui">{review_reason(warning)}</p>
          </li>
        </ul>

        <:footer>
          <.button
            id="sales-bills-tally-warning-cancel"
            type="button"
            variant="ghost"
            phx-click="cancel-send-to-tally"
          >
            Cancel
          </.button>
          <.button
            id="sales-bills-tally-warning-confirm"
            type="button"
            phx-click="send-to-tally"
          >
            Send {length(@packet.invoices)} anyway
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@selected_invoice}
        id="sales-bill-posting-review"
        title={"Invoice #{@selected_invoice["invoice_number"] || "without a number"}"}
        on_close="close-posting-review"
        variant="workbench"
        close_on_escape={
          is_nil(@editing_line_index) and not @editing_invoice_facts? and not @evidence_open and
            is_nil(@ledger_picker.picker)
        }
      >
        <:header :let={title_id}>
          <div class="flex items-center justify-between gap-3">
            <h2 id={title_id} class="sr-only">
              Invoice {@selected_invoice["invoice_number"] || "without a number"}
            </h2>
            <div>
              <.button
                id="sales-bill-posting-back"
                type="button"
                variant="ghost"
                size="xs"
                phx-click="close-posting-review"
              >
                <.icon name="hero-arrow-left" class="size-4" /> Back to batch
              </.button>
            </div>
            <div class="border-base-300 gap-related flex items-center border-r pr-4">
              <.button
                id="sales-bill-posting-previous"
                type="button"
                variant="ghost"
                size="xs"
                phx-click="navigate-posting-review"
                phx-value-item={invoice_id(@posting_navigation.previous)}
                disabled={is_nil(@posting_navigation.previous)}
                aria-label="Previous invoice"
                title="Previous invoice"
              >
                <.icon name="hero-chevron-left" class="size-4" />
              </.button>
              <span id="sales-bill-posting-position" class="text-ink-subtle text-ui tabular-nums">
                {@posting_navigation.position} of {@posting_navigation.total}
              </span>
              <.button
                id="sales-bill-posting-next"
                type="button"
                variant="ghost"
                size="xs"
                phx-click="navigate-posting-review"
                phx-value-item={invoice_id(@posting_navigation.next)}
                disabled={is_nil(@posting_navigation.next)}
                aria-label="Next invoice"
                title="Next invoice"
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </.button>
            </div>
          </div>
        </:header>

        <div
          id="sales-bill-posting-review-keys"
          phx-hook=".SalesBillPostingReviewKeys"
          data-previous-item={invoice_id(@posting_navigation.previous)}
          data-next-item={invoice_id(@posting_navigation.next)}
          data-navigation-enabled={
            if(
              is_nil(@editing_line_index) and not @editing_invoice_facts? and not @evidence_open,
              do: "true",
              else: "false"
            )
          }
          class="gap-block grid h-full min-h-0 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:grid-rows-[minmax(0,1fr)]"
        >
          <section id="sales-bill-original" class="min-h-0 overflow-y-auto">
            <.evidence_frame
              :if={@selected_invoice["image_urls"] != []}
              id="sales-bill-evidence-frame"
              images={@selected_invoice["image_urls"]}
              page={@evidence_page}
              label="Original invoice"
              on_open="open-posting-evidence"
              on_page="posting-evidence-page"
            />
            <div
              :if={@selected_invoice["image_urls"] == []}
              id="sales-bill-evidence-unavailable"
              class="border-base-300 rounded-box text-body text-ink-muted flex h-full min-h-48 items-center justify-center border border-dashed"
            >
              No rendered invoice page is available.
            </div>
          </section>

          <section id="sales-bill-proposed-voucher" class="min-h-0 overflow-y-auto">
            <div
              :if={@tally_company && not @tally_masters_available?}
              id="sales-bill-tally-masters-unavailable"
            >
              <.callout kind="warning" size="compact" title="Import Tally ledgers to get started">
                {tally_master_sync_instruction(assigns)}
              </.callout>
            </div>

            <div
              :if={is_nil(@tally_company)}
              id="sales-bill-tally-company-unavailable"
            >
              <.callout kind="warning" size="compact" title="No Tally company selected">
                Select this client's Tally company to choose posting ledgers and send vouchers.
              </.callout>
            </div>

            <.form
              :if={@tally_posting}
              for={@tally_posting.form}
              id="sales-bill-tally-posting-form"
              phx-submit="save-tally-posting"
              phx-change="preview-tally-posting"
            >
              <div class="pb-canvas space-y-section">
                <section id="sales-bill-invoice-facts" class="space-y-block max-w-3xl">
                  <div class="flex items-start justify-between gap-3">
                    <div class="space-y-related">
                      <h3
                        id="sales-bill-invoice-identity"
                        class="text-base-content text-h4 font-semibold"
                      >
                        Invoice {@posting_preview_invoice["invoice_number"] || "without a number"}
                      </h3>
                      <p id="sales-bill-buyer-identity" class="text-ink-muted text-ui">
                        <span :if={@posting_preview_invoice["invoice_date"]}>
                          {format_display_date(@posting_preview_invoice["invoice_date"])} ·
                        </span>
                        {@posting_preview_invoice["buyer_name"] || "Buyer not identified"}
                      </p>
                      <p
                        :if={@posting_preview_invoice["buyer_gstin"]}
                        id="sales-bill-buyer-gstin"
                        class="text-ink-muted text-ui"
                      >
                        {@posting_preview_invoice["buyer_gstin"]}
                      </p>
                      <p :if={@tally_company} class="text-ink-muted text-ui">
                        Tally · {@tally_company.name}
                        <span
                          :if={not @tally_online? && @tally_masters_available?}
                          id="sales-bill-tally-offline"
                          class="text-warning"
                        >
                          · Offline — masters synced {format_master_sync(@tally_masters_synced_at)}
                        </span>
                      </p>
                    </div>
                    <.button
                      id="sales-bill-edit-invoice-facts"
                      type="button"
                      variant="ghost"
                      size="xs"
                      phx-click="edit-invoice-facts"
                      phx-value-return_to="#sales-bill-edit-invoice-facts"
                    >
                      <.icon name="hero-pencil-square" class="size-4" /> Edit invoice facts
                    </.button>
                  </div>

                  <.callout
                    :for={{item, index} <- Enum.with_index(review_items(@selected_review, :facts))}
                    kind="warning"
                    size="compact"
                    title={item.summary}
                  >
                    <div class="gap-related flex items-start justify-between">
                      <span>{review_item_copy(item)}</span>
                      <.button
                        id={"sales-bill-fix-invoice-fact-#{index}"}
                        type="button"
                        variant="ghost"
                        size="xs"
                        phx-click="edit-invoice-facts"
                        phx-value-field={review_item_focus(item)}
                        phx-value-return_to={"#sales-bill-fix-invoice-fact-#{index}"}
                      >
                        Fix
                      </.button>
                    </div>
                  </.callout>

                  <div>
                    <.input
                      id="tally-posting-invoice-number-value"
                      name="tally_posting[invoice][invoice_number]"
                      value={@posting_preview_invoice["invoice_number"]}
                      type="hidden"
                    />
                    <.input
                      id="tally-posting-invoice-date-value"
                      name="tally_posting[invoice][invoice_date]"
                      value={@posting_preview_invoice["invoice_date"]}
                      type="hidden"
                    />
                    <.input
                      id="tally-posting-buyer-name-value"
                      name="tally_posting[invoice][buyer_name]"
                      value={@posting_preview_invoice["buyer_name"]}
                      type="hidden"
                    />
                    <.input
                      id="tally-posting-buyer-gstin-value"
                      name="tally_posting[invoice][buyer_gstin]"
                      value={@posting_preview_invoice["buyer_gstin"]}
                      type="hidden"
                    />
                  </div>
                </section>

                <section
                  :if={review_items(@selected_review, :global) != []}
                  id="sales-bill-global-review"
                  class="space-y-related max-w-3xl"
                >
                  <div
                    :for={{item, index} <- Enum.with_index(review_items(@selected_review, :global))}
                    id={"sales-bill-review-global-#{index}"}
                  >
                    <.callout kind="warning" size="compact" title={item.summary}>
                      <span :if={item.detail}>{item.detail}</span>
                    </.callout>
                  </div>
                </section>

                <section id="sales-bill-accounting-mappings" class="space-y-block">
                  <div class="space-y-related max-w-3xl">
                    <div class="gap-related flex items-baseline">
                      <h3 class="text-base-content text-h4 font-semibold">Accounting mappings</h3>
                      <span id="sales-bill-mappings-remaining" class="text-ink-muted text-ui">
                        {if(@tally_masters_available?,
                          do: missing_mapping_text(@tally_posting),
                          else: "Available after master sync"
                        )}
                      </span>
                    </div>

                    <div id="sales-bill-party-mapping" class="max-w-lg">
                      <.ledger_picker_field
                        id="tally_posting_party_ledger_identity"
                        name="tally_posting[party_ledger_identity]"
                        label="Tally party ledger"
                        prompt="Select party ledger"
                        options={@tally_posting.party_choices}
                        value={@tally_posting.form[:party_ledger_identity].value}
                        picker="party"
                        panel_id="sales-bill-ledger-picker"
                        on_open="open-ledger-picker"
                        disabled={not @tally_masters_available?}
                      />
                    </div>
                  </div>

                  <section id="sales-bill-ledger-allocations" class="space-y-related">
                    <div class="flex items-baseline justify-between gap-3">
                      <h3 class="text-base-content text-ui font-semibold">Ledger allocations</h3>
                      <span class="text-ink-subtle text-ui">
                        {length(@tally_posting.line_rows)} {plural(
                          length(@tally_posting.line_rows),
                          "line"
                        )}
                      </span>
                    </div>
                    <div
                      :for={
                        {item, index} <-
                          Enum.with_index(review_items(@selected_review, :allocations))
                      }
                      id={"sales-bill-review-allocation-#{index}"}
                    >
                      <.callout kind="warning" size="compact" title={item.summary}>
                        <span>{review_item_copy(item)}</span>
                      </.callout>
                    </div>
                    <.data_table
                      id="sales-bill-posting-lines"
                      rows={@tally_posting.line_rows}
                      row_id={fn row -> "sales-bill-posting-line-#{row.index}" end}
                      mode="review"
                      min_width="min-w-[760px]"
                    >
                      <:col :let={row} label="Invoice line" row_header class="w-2/5 min-w-72">
                        <div id={"sales-bill-line-summary-#{row.index}"} class="space-y-1">
                          <p class="text-base-content text-ui font-medium">
                            {row.line["description"] || row.line["item_name"] || "Unnamed line"}
                          </p>
                          <p class="text-ink-muted text-ui">
                            HSN {row.line["hsn_sac"] || "—"} · {working_number(row.line["quantity"])} {row.line[
                              "uom"
                            ]} × {rupees(
                              row.line["printed_unit_price"] || row.line["unit_price"] ||
                                row.line["rate"]
                            )}
                          </p>
                          <p
                            :for={item <- review_line_items(@selected_review, row.index)}
                            class="text-ui text-warning font-medium"
                          >
                            {item.summary}
                          </p>
                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][description]"}
                            value={row.line["description"] || row.line["item_name"]}
                          />
                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][hsn_sac]"}
                            value={row.line["hsn_sac"]}
                          />
                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][quantity]"}
                            value={row.line["quantity"]}
                          />
                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][uom]"}
                            value={row.line["uom"]}
                          />
                          <.input
                            type="hidden"
                            name={"tally_posting[invoice][line_items][#{row.index}][rate]"}
                            value={
                              row.line["printed_unit_price"] || row.line["unit_price"] ||
                                row.line["rate"]
                            }
                          />
                        </div>
                      </:col>
                      <:col :let={row} label="Taxable" align="right" class="w-32">
                        <div class="tabular-nums">
                          <span class="text-base-content text-ui block font-medium">
                            {rupees(row.line["taxable_value"])}
                          </span>
                        </div>
                        <.input
                          type="hidden"
                          name={"tally_posting[invoice][line_items][#{row.index}][taxable_value]"}
                          value={row.line["taxable_value"]}
                        />
                      </:col>
                      <:col :let={row} label="GST" align="right" class="w-44">
                        <div class="space-y-1 text-right tabular-nums">
                          <span :if={row.tax_rows == []} class="text-ink-muted text-ui">—</span>
                          <div
                            :for={tax <- row.tax_rows}
                            class="text-ui flex items-baseline justify-end gap-1 whitespace-nowrap tabular-nums"
                          >
                            <span class="text-base-content font-medium whitespace-nowrap">
                              {tax.label} {working_number(tax.rate)}%
                            </span>
                            <span class="text-ink-muted whitespace-nowrap">
                              · {rupees(tax.amount)}
                            </span>
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][#{tax.head}_rate]"}
                              value={tax.rate}
                            />
                            <.input
                              type="hidden"
                              name={"tally_posting[invoice][line_items][#{row.index}][#{tax.head}_amount]"}
                              value={tax.amount}
                            />
                          </div>
                        </div>
                      </:col>
                      <:col :let={row} label="Tally sales ledger" class="w-1/4 min-w-60 align-middle">
                        <.ledger_picker_field
                          id={"tally-posting-line-sales-ledger-#{row.index}"}
                          name={"tally_posting[line_sales_ledger_identities][#{row.index}]"}
                          value={row.sales_ledger_identity}
                          label={"Line #{row.index + 1} Tally sales ledger"}
                          prompt="Select ledger"
                          options={@tally_posting.sales_choices}
                          picker={"sales:#{row.index}"}
                          panel_id="sales-bill-ledger-picker"
                          on_open="open-ledger-picker"
                          hide_label
                          disabled={not @tally_masters_available?}
                        />
                      </:col>
                      <:col :let={row} label="" align="center" class="w-10 align-middle">
                        <button
                          id={"sales-bill-edit-line-#{row.index}"}
                          type="button"
                          class={[
                            "focus-visible:outline-focus rounded-field text-ink-subtle grid size-8 place-items-center transition focus-visible:outline-2 focus-visible:outline-offset-2",
                            not invoice_frozen?(
                              @tally_jobs,
                              @selected_invoice,
                              @packet.all_invoices
                            ) &&
                              "hover:bg-base-200 hover:text-ink cursor-pointer",
                            invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices) &&
                              "cursor-not-allowed opacity-50"
                          ]}
                          phx-click="edit-posting-line"
                          phx-value-index={row.index}
                          disabled={
                            invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)
                          }
                          aria-label={"Edit invoice line #{row.index + 1}"}
                          title={
                            if(
                              invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices),
                              do: "Locked after sending",
                              else: "Edit line"
                            )
                          }
                        >
                          <.icon name="hero-pencil-square" class="size-4" />
                        </button>
                      </:col>
                    </.data_table>
                  </section>

                  <section id="sales-bill-tax-posting" class="space-y-related max-w-3xl">
                    <h3 class="text-base-content text-ui font-semibold">Tax ledgers</h3>
                    <div
                      :for={row <- @tally_posting.tax_rows}
                      id={"sales-bill-tax-row-#{row.head}"}
                      class="gap-block grid items-center sm:grid-cols-[7rem_minmax(0,32rem)_auto]"
                    >
                      <span class="text-base-content text-ui font-medium">
                        {tax_posting_label(@posting_preview_invoice, row.head, row.label)}
                      </span>
                      <.ledger_picker_field
                        id={"tally_posting_#{row.head}_ledger_identity"}
                        name={"tally_posting[#{row.head}_ledger_identity]"}
                        prompt={"Select #{row.label} ledger"}
                        options={@tally_posting.tax_choices}
                        value={@tally_posting.form[row.field].value}
                        label={"#{row.label} ledger"}
                        picker={"tax:#{row.head}"}
                        panel_id="sales-bill-ledger-picker"
                        on_open="open-ledger-picker"
                        hide_label
                        disabled={not @tally_masters_available?}
                      />
                      <span class="text-base-content text-ui text-right font-medium tabular-nums">
                        {rupees(row.amount)}
                      </span>
                    </div>
                  </section>
                </section>

                <section id="sales-bill-narration" class="space-y-related max-w-3xl">
                  <div class="flex items-center justify-between gap-3">
                    <h3 class="text-base-content text-ui font-semibold">Narration</h3>
                    <.button
                      :if={not @editing_narration?}
                      id="sales-bill-edit-narration"
                      type="button"
                      variant="ghost"
                      size="xs"
                      phx-click="edit-narration"
                    >
                      Edit
                    </.button>
                    <.button
                      :if={@editing_narration?}
                      id="sales-bill-finish-narration"
                      type="button"
                      variant="ghost"
                      size="xs"
                      phx-click="finish-narration"
                    >
                      Done
                    </.button>
                  </div>

                  <p
                    :if={not @editing_narration?}
                    id="sales-bill-narration-value"
                    class="text-ink-muted text-ui"
                  >
                    {narration(@posting_preview_invoice)}
                  </p>
                  <.input
                    :if={not @editing_narration?}
                    id="tally-posting-narration-value"
                    name="tally_posting[invoice][narration]"
                    value={narration(@posting_preview_invoice)}
                    type="hidden"
                  />
                  <.input
                    :if={@editing_narration?}
                    id="tally-posting-narration"
                    name="tally_posting[invoice][narration]"
                    value={narration(@posting_preview_invoice)}
                    type="textarea"
                    aria-label="Narration"
                    rows="2"
                  />
                </section>

                <.callout
                  :if={total_mismatch?(@posting_preview_invoice)}
                  kind="warning"
                  size="compact"
                  title="Invoice total does not match the lines"
                >
                  The lines calculate to {rupees(invoice_total(@posting_preview_invoice))}; the invoice
                  prints {rupees(printed_total(@posting_preview_invoice))}. Review the figures, or sync if
                  this is the voucher the accountant intends to post.
                </.callout>

                <p
                  :if={@send_error}
                  id="sales-bill-posting-send-error"
                  class="text-error text-ui"
                >
                  {@send_error}
                </p>

                <div
                  :if={
                    selected_delivery_state(
                      selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                    ) ==
                      :sending
                  }
                  id="sales-bill-posting-sending"
                  class="text-base-content text-ui flex items-center gap-2 font-semibold"
                >
                  <.spinner tone="accent" label="Sending to Tally" /> Sending to Tally
                </div>
                <p
                  :if={
                    selected_delivery_state(
                      selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                    ) ==
                      :added
                  }
                  id="sales-bill-posting-added"
                  class="text-success text-ui font-semibold"
                >
                  Added to Tally and verified
                </p>
                <.callout
                  :if={
                    selected_delivery_state(
                      selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                    ) ==
                      :unknown
                  }
                  kind="warning"
                  size="compact"
                  title="Tally outcome needs verification"
                >
                  Nila could not confirm whether this voucher was added. Use Check Tally from the batch.
                </.callout>
                <p
                  :if={
                    selected_delivery_state(
                      selected_tally_job(@tally_jobs, @selected_invoice, @packet.all_invoices)
                    ) ==
                      :failed
                  }
                  id="sales-bill-posting-failed"
                  class="text-error text-ui"
                >
                  This voucher was not added to Tally. Correct it and try again.
                </p>
              </div>

              <div class="bg-base-100 border-base-300 sticky bottom-0 border-t py-4">
                <div
                  :if={@selected_review}
                  id="sales-bill-next-review-issue"
                  class="gap-block flex flex-col lg:flex-row lg:items-center lg:justify-between"
                >
                  <div class="min-w-0">
                    <p class="text-base-content text-ui font-semibold">
                      {length(@selected_review.items)} {plural(
                        length(@selected_review.items),
                        "review issue"
                      )}
                    </p>
                    <p class="text-ink-muted text-ui truncate">
                      Next: {next_review_item(@selected_review).summary}
                    </p>
                  </div>

                  <div class="gap-block flex items-center justify-end">
                    <p class="text-base-content text-ui font-semibold tabular-nums">
                      {rupees(invoice_total(@posting_preview_invoice))}
                    </p>
                    <.button
                      id="sales-bill-go-to-review-issue"
                      type="button"
                      variant="outline"
                      phx-click={JS.focus(to: review_item_target(next_review_item(@selected_review)))}
                    >
                      Review
                    </.button>
                  </div>
                </div>

                <div
                  :if={
                    is_nil(@selected_review) && @tally_masters_available? &&
                      next_posting_requirement(@tally_posting)
                  }
                  id="sales-bill-next-required-mapping"
                  class="gap-block flex flex-col lg:flex-row lg:items-center lg:justify-between"
                >
                  <div class="min-w-0">
                    <p class="text-base-content text-ui font-semibold">
                      {length(posting_requirements(@tally_posting))} {plural(
                        length(posting_requirements(@tally_posting)),
                        "mapping"
                      )} left
                    </p>
                    <p class="text-ink-muted text-ui truncate">
                      Next: {next_posting_requirement(@tally_posting).label}
                    </p>
                  </div>

                  <div class="gap-block flex items-center justify-end">
                    <p class="text-base-content text-ui font-semibold tabular-nums">
                      {rupees(invoice_total(@posting_preview_invoice))}
                    </p>
                    <.ledger_picker_shortcut
                      id="sales-bill-go-to-required-mapping"
                      trigger_id={next_posting_requirement(@tally_posting).trigger_id}
                    >
                      Choose ledger
                    </.ledger_picker_shortcut>
                  </div>
                </div>

                <div
                  :if={
                    is_nil(@selected_review) && @tally_masters_available? &&
                      is_nil(next_posting_requirement(@tally_posting))
                  }
                  id="sales-bill-posting-ready"
                  class="gap-block flex flex-col lg:flex-row lg:items-end lg:justify-between"
                >
                  <dl class="text-ui grid flex-1 grid-cols-3 gap-3">
                    <div>
                      <dt class="text-ink-subtle">Taxable</dt>
                      <dd class="text-base-content mt-1 font-medium tabular-nums">
                        {rupees(totals(@posting_preview_invoice).taxable)}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-ink-subtle">Tax</dt>
                      <dd class="text-base-content mt-1 font-medium tabular-nums">
                        {rupees(totals(@posting_preview_invoice).tax)}
                      </dd>
                    </div>
                    <div>
                      <dt class="text-base-content font-medium">Voucher total</dt>
                      <dd class="text-base-content mt-1 font-semibold tabular-nums">
                        {rupees(invoice_total(@posting_preview_invoice))}
                      </dd>
                    </div>
                  </dl>

                  <div class="gap-related flex justify-end">
                    <.button
                      id="sales-bill-save-tally-posting"
                      type="submit"
                      disabled={invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)}
                    >
                      {if(@review_mode?, do: "Save & next", else: "Save & Close")}
                    </.button>
                  </div>
                </div>

                <div
                  :if={not @tally_masters_available?}
                  id="sales-bill-posting-awaiting-masters"
                  class="gap-block flex items-end justify-between"
                >
                  <p class="text-ink-muted text-ui">
                    Tally mappings are available after the first master sync.
                  </p>
                  <p class="text-base-content text-ui font-semibold tabular-nums">
                    {rupees(invoice_total(@posting_preview_invoice))}
                  </p>
                </div>
              </div>
            </.form>

            <.ledger_picker_panel
              :if={@tally_posting}
              id="sales-bill-ledger-picker"
              title={@ledger_picker.title}
              form={@ledger_picker.form}
              options={@ledger_picker.options}
              selected_identity={@ledger_picker.selected_identity}
              on_filter="filter-ledger-picker"
              on_submit="choose-first-ledger"
              on_select="choose-ledger"
              on_close="close-ledger-picker"
            />

            <.modal
              :if={@editing_invoice_facts? && @invoice_facts_form}
              id="sales-bill-invoice-facts-sheet"
              title="Edit invoice facts"
              on_close="close-invoice-facts"
              variant="sheet"
              side="right"
              return_focus={@invoice_facts_return_focus}
            >
              <.form
                for={@invoice_facts_form}
                id="sales-bill-invoice-facts-form"
                phx-hook=".InvoiceFactsFocus"
                data-focus-field={@invoice_facts_focus}
                phx-submit="save-invoice-facts"
                class="space-y-block p-6"
              >
                <div class="gap-block grid grid-cols-2">
                  <.input
                    field={@invoice_facts_form[:invoice_number]}
                    label="Invoice number"
                    required
                    autofocus={@invoice_facts_focus == "invoice_number"}
                  />
                  <.input
                    field={@invoice_facts_form[:invoice_date]}
                    type="date"
                    label="Invoice date"
                    required
                    autofocus={@invoice_facts_focus == "invoice_date"}
                  />
                </div>

                <.input
                  field={@invoice_facts_form[:buyer_name]}
                  label="Buyer name"
                  required
                  autofocus={@invoice_facts_focus == "buyer_name"}
                />
                <.input
                  field={@invoice_facts_form[:buyer_gstin]}
                  label="Buyer GSTIN"
                  autofocus={@invoice_facts_focus == "buyer_gstin"}
                />
                <p
                  :if={@invoice_facts_error}
                  id="sales-bill-invoice-facts-error"
                  class="text-error text-ui"
                >
                  {@invoice_facts_error}
                </p>
              </.form>

              <:footer>
                <.button type="button" variant="ghost" phx-click="close-invoice-facts">
                  Cancel
                </.button>
                <.button type="submit" form="sales-bill-invoice-facts-form">
                  Save changes
                </.button>
              </:footer>
            </.modal>

            <.modal
              :if={@line_edit_form && @line_edit_row}
              id="sales-bill-line-edit-sheet"
              title="Edit invoice line"
              on_close="close-posting-line"
              variant="sheet"
              side="right"
              return_focus={"#sales-bill-edit-line-#{@editing_line_index}"}
            >
              <.form
                for={@line_edit_form}
                id="sales-bill-line-edit-form"
                phx-submit="save-posting-line"
                class="space-y-block p-6"
              >
                <.input
                  field={@line_edit_form[:description]}
                  label="Description"
                  required
                />
                <.input field={@line_edit_form[:hsn_sac]} label="HSN / SAC" required />

                <div class="gap-block grid grid-cols-2">
                  <.input
                    field={@line_edit_form[:quantity]}
                    type="number"
                    label="Quantity"
                    step="any"
                    required
                  />
                  <.input field={@line_edit_form[:uom]} label="Unit" />
                </div>

                <div class="gap-block grid grid-cols-2">
                  <.input
                    field={@line_edit_form[:rate]}
                    type="number"
                    label="Rate"
                    step="any"
                    required
                  />
                  <.input
                    field={@line_edit_form[:taxable_value]}
                    type="number"
                    label="Taxable value"
                    step="any"
                    required
                  />
                </div>

                <section
                  :if={@line_edit_row.tax_rows != []}
                  class="border-base-300 space-y-related border-t pt-4"
                >
                  <h4 class="text-base-content text-ui font-semibold">GST</h4>
                  <div
                    :for={tax <- @line_edit_row.tax_rows}
                    class="gap-block grid grid-cols-2"
                  >
                    <.input
                      field={@line_edit_form[tax_edit_field(tax.head, :rate)]}
                      type="number"
                      label={"#{tax.label} rate %"}
                      step="any"
                      required
                    />
                    <.input
                      field={@line_edit_form[tax_edit_field(tax.head, :amount)]}
                      type="number"
                      label={"#{tax.label} amount"}
                      step="any"
                      required
                    />
                  </div>
                </section>

                <p :if={@line_edit_error} id="sales-bill-line-edit-error" class="text-error text-ui">
                  {@line_edit_error}
                </p>
              </.form>

              <:footer>
                <.button type="button" variant="ghost" phx-click="close-posting-line">
                  Cancel
                </.button>
                <.button type="submit" form="sales-bill-line-edit-form">
                  Save changes
                </.button>
              </:footer>
            </.modal>
          </section>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SalesBillPostingReviewKeys">
          export default {
            mounted() {
              this.onKeydown = event => {
                if (
                  this.el.dataset.navigationEnabled !== "true" ||
                  event.defaultPrevented ||
                  event.altKey ||
                  event.ctrlKey ||
                  event.metaKey ||
                  event.shiftKey ||
                  event.target.closest("input, textarea, select, [contenteditable='true']")
                ) return

                const item = event.key === "ArrowLeft"
                  ? this.el.dataset.previousItem
                  : event.key === "ArrowRight"
                    ? this.el.dataset.nextItem
                    : null

                if (!item) return

                event.preventDefault()
                this.pushEvent("navigate-posting-review", {item})
              }

              window.addEventListener("keydown", this.onKeydown)
            },

            destroyed() {
              window.removeEventListener("keydown", this.onKeydown)
            }
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".InvoiceFactsFocus">
          export default {
            mounted() {
              const field = this.el.dataset.focusField
              const target = field
                ? this.el.querySelector(`[name="invoice_facts[${field}]"]`)
                : this.el.querySelector("input, select, textarea")

              requestAnimationFrame(() => target?.focus())
            }
          }
        </script>
      </.modal>

      <.evidence_overlay
        :if={(@evidence_open and @selected_invoice) && @selected_invoice["image_urls"] != []}
        id="sales-bill-evidence-overlay"
        images={@selected_invoice["image_urls"]}
        page={@evidence_page}
        title={@selected_invoice["invoice_number"] || "Invoice"}
        on_close="close-posting-evidence"
        on_page="posting-evidence-page"
      />
    </Layouts.app>
    """
  end
end
