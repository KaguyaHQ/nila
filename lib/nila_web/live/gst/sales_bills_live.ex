defmodule NilaWeb.Gst.SalesBillsLive do
  use NilaWeb, :live_view

  alias Nila.Clients
  alias Nila.Gst.Filing.TallyPrime
  alias Nila.Gst.Sales.{Gstr1, InvoiceCorrections, InvoiceRemovals, TallyPacket}
  alias Nila.Gst.StateCodes
  alias Nila.{TallyDevices, TallyJobs, TallyMappings}
  alias NilaWeb.Gst.SalesIssuePresentation
  alias NilaWeb.Presence

  @impl true
  def mount(%{"client_id" => client_id, "batch_ref" => batch_ref}, _session, socket) do
    org_id = socket.assigns.current_scope.current_org.id

    with {:ok, client} <- Clients.get_client(org_id, client_id),
         {:ok, dumps} <- TallyPacket.fetch(org_id, client_id, batch_ref) do
      if connected?(socket), do: TallyJobs.subscribe_org(org_id)

      companies = online_tally_companies(org_id, client.id)
      company = List.first(companies)
      source_prefix = company && tally_source_prefix(batch_ref, company.id)
      packet = prepare_packet(dumps, client.id)
      tally_jobs = list_tally_jobs(org_id, source_prefix)

      {:ok,
       socket
       |> assign(:page_title, "Sales bills")
       |> assign(:client, client)
       |> assign(:batch_ref, batch_ref)
       |> assign(:packet, packet)
       |> assign(:tally_companies, companies)
       |> assign(:tally_company, company)
       |> assign(:tally_company_form, tally_company_form(company))
       |> assign(:tally_source_prefix, source_prefix)
       |> assign(:tally_jobs, tally_jobs)
       |> assign(:selected_invoice, nil)
       |> assign(:posting_preview_invoice, nil)
       |> assign(:tally_posting, nil)
       |> assign(:posting_navigation, %{previous: nil, next: nil, position: 0, total: 0})
       |> assign(:evidence_open, false)
       |> assign(:evidence_page, 0)
       |> assign(:editing_line_index, nil)
       |> assign(:line_edit_row, nil)
       |> assign(:line_edit_form, nil)
       |> assign(:line_edit_error, nil)
       |> assign(:removing_invoice, nil)
       |> assign(:send_holds, current_send_holds(org_id, company, packet))
       |> assign(:send_error, nil)}
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

    {:noreply,
     socket
     |> assign(:selected_invoice, invoice)
     |> assign(:selected_review, selected_review)
     |> assign(:posting_preview_invoice, invoice)
     |> assign(:tally_posting, tally_posting(socket.assigns, invoice))
     |> assign(
       :posting_navigation,
       posting_navigation(socket.assigns.packet.all_invoices, invoice)
     )
     |> assign(
       :editing_line_index,
       if(previous_id == invoice_id(invoice), do: socket.assigns.editing_line_index, else: nil)
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

  defp totals(invoice), do: Nila.Gst.Sales.Gstr1.extracted_totals(invoice)

  defp invoice_total(invoice) do
    amounts = totals(invoice)

    if is_number(amounts.taxable) and is_number(amounts.tax),
      do: amounts.taxable + amounts.tax
  end

  defp state_options, do: Enum.map(StateCodes.all(), &{&1, StateCodes.code_for(&1)})

  defp printed_total(invoice), do: invoice["printed_grand_total"]

  defp total_mismatch?(invoice) do
    calculated = invoice_total(invoice)
    printed = printed_total(invoice)

    is_number(calculated) and is_number(printed) and abs(calculated - printed) > 0.01
  end

  defp rupees(value) when is_number(value),
    do: Nila.Formatters.format_money_with_paise(round(value * 100))

  defp rupees(value) when is_binary(value) do
    case Float.parse(String.replace(String.trim(value), ",", "")) do
      {number, ""} -> rupees(number)
      _invalid -> "—"
    end
  end

  defp rupees(_value), do: "—"

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
  def handle_event(
        "select-tally-company",
        %{"tally_company" => %{"company_id" => company_id}},
        socket
      ) do
    org_id = socket.assigns.current_scope.current_org.id
    companies = online_tally_companies(org_id, socket.assigns.client.id)

    company =
      with {company_id, ""} <- Integer.parse(company_id) do
        Enum.find(companies, &(&1.id == company_id))
      else
        _invalid -> nil
      end

    if company && socket.assigns.tally_jobs == [] do
      source_prefix = tally_source_prefix(socket.assigns.batch_ref, company.id)

      socket =
        socket
        |> assign(:tally_companies, companies)
        |> assign(:tally_company, company)
        |> assign(:tally_company_form, tally_company_form(company))
        |> assign(:tally_source_prefix, source_prefix)
        |> assign(:tally_jobs, [])
        |> assign(:send_holds, current_send_holds(org_id, company, socket.assigns.packet))
        |> assign(:send_error, nil)

      {:noreply,
       assign(
         socket,
         :tally_posting,
         tally_posting(socket.assigns, socket.assigns.selected_invoice)
       )}
    else
      {:noreply,
       socket
       |> assign(:tally_companies, companies)
       |> assign(:send_error, "Choose a currently connected Tally company.")}
    end
  end

  def handle_event("send-to-tally", _params, socket) do
    org_id = socket.assigns.current_scope.current_org.id
    company = socket.assigns.tally_company

    with %{} <- company,
         {:ok, company} <- online_tally_company(org_id, socket.assigns.client.id, company.id),
         :ok <- TallyPrime.validate_company_gstin(company, socket.assigns.client.gstin),
         {:ok, invoices, unresolved_parties} <-
           apply_tally_posting(org_id, company.id, socket.assigns.packet.invoices),
         {items, unbuildable} <- build_tally_items(invoices, company.name),
         {ready, blocked} <- partition_ready_items(company.id, items),
         {:ok, _jobs} <-
           TallyJobs.enqueue_vouchers(company, ready,
             source_prefix: socket.assigns.tally_source_prefix
           ) do
      {:noreply,
       socket
       |> assign(:tally_company, company)
       |> assign(:tally_jobs, list_tally_jobs(org_id, socket.assigns.tally_source_prefix))
       |> assign(:send_holds, send_holds(unresolved_parties, unbuildable, blocked))
       |> assign(:send_error, send_blocked_message(unresolved_parties, unbuildable, blocked))}
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

  def handle_event("close-posting-review", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/sales-bills/#{socket.assigns.client.id}/batch/#{socket.assigns.batch_ref}"
     )}
  end

  def handle_event("open-remove-invoice", %{"id" => source_id}, socket) do
    invoice = Enum.find(socket.assigns.packet.all_invoices, &(invoice_id(&1) == source_id))

    if invoice && not invoice_frozen_now?(socket, invoice) do
      {:noreply, assign(socket, :removing_invoice, invoice)}
    else
      {:noreply,
       put_flash(socket, :error, "Invoices cannot be removed after this batch is sent.")}
    end
  end

  def handle_event("close-remove-invoice", _params, socket),
    do: {:noreply, assign(socket, :removing_invoice, nil)}

  def handle_event(
        "remove-invoice",
        _params,
        %{assigns: %{removing_invoice: invoice}} = socket
      )
      when not is_nil(invoice) do
    scope = socket.assigns.current_scope
    org_id = scope.current_org.id

    with false <- invoice_frozen_now?(socket, invoice),
         {:ok, _removal} <-
           InvoiceRemovals.remove(
             org_id,
             socket.assigns.client.id,
             socket.assigns.batch_ref,
             invoice_id(invoice),
             scope.user.id
           ),
         {:ok, dumps} <-
           TallyPacket.fetch(org_id, socket.assigns.client.id, socket.assigns.batch_ref) do
      {:noreply,
       socket
       |> assign(:packet, prepare_packet(dumps, socket.assigns.client.id))
       |> assign(:removing_invoice, nil)}
    else
      true ->
        {:noreply,
         socket
         |> assign(:removing_invoice, nil)
         |> put_flash(
           :error,
           "This invoice was sent while the dialog was open, so it was not removed."
         )}

      _error ->
        {:noreply,
         socket
         |> assign(:removing_invoice, nil)
         |> put_flash(:error, "That invoice could not be removed.")}
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
           to: posting_review_path(socket.assigns.client, socket.assigns.batch_ref, invoice)
         )}
    end
  end

  def handle_event("open-posting-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, true)}

  def handle_event("close-posting-evidence", _params, socket),
    do: {:noreply, assign(socket, :evidence_open, false)}

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
      source_id = Gstr1.source_id(invoice)
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
        %{assigns: %{tally_company: %{id: company_id}, selected_invoice: invoice}} = socket
      )
      when not is_nil(invoice) do
    if invoice_frozen_now?(socket, invoice) do
      {:noreply, put_flash(socket, :error, "Sent invoice data is locked to its Tally job.")}
    else
      save_tally_posting(socket, posting, params, company_id, invoice)
    end
  end

  def handle_event("save-tally-posting", _params, socket), do: {:noreply, socket}

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

    with {:ok, %{invoice: corrected_invoice}} <-
           InvoiceCorrections.save_workbench(
             org_id,
             socket.assigns.client.id,
             socket.assigns.batch_ref,
             Gstr1.source_id(invoice),
             company_id,
             %{
               invoice: posting["invoice"] || editable_invoice_values(invoice),
               party_ledger_identity: posting["party_ledger_identity"],
               posting_profile: profile_attrs,
               line_sales_ledger_identities: posting["line_sales_ledger_identities"] || %{}
             },
             socket.assigns.current_scope.user.id
           ) do
      socket = replace_selected_invoice(socket, corrected_invoice)

      {:noreply,
       socket
       |> put_flash(:info, "Tally posting saved.")
       |> push_patch(
         to: ~p"/sales-bills/#{socket.assigns.client.id}/batch/#{socket.assigns.batch_ref}"
       )}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That Tally posting could not be saved.")}
    end
  end

  defp replace_selected_invoice(socket, corrected_invoice) do
    source_id = Gstr1.source_id(corrected_invoice)
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
    source_id = Gstr1.source_id(corrected_invoice)
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
      "place_of_supply" => invoice["place_of_supply"],
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
        ~w(invoice_number invoice_date buyer_name buyer_gstin place_of_supply narration),
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

  defp preview_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _invalid -> nil
    end
  end

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
    failed = Enum.map(packet.failed_files, &TallyPacket.original_name/1)
    unread = Enum.map(packet.unread_pages, &"#{&1.file} · page #{&1.page}")

    not_added =
      tally_jobs
      |> Enum.filter(&(&1.status in ["failed", "indeterminate"]))
      |> Enum.map(&(&1.payload["invoice_number"] || "Unnumbered bill"))

    missing_jobs = missing_job_invoice_numbers(packet.invoices, tally_jobs)

    Enum.uniq(failed ++ unread ++ not_added ++ missing_jobs)
  end

  defp missing_job_invoice_numbers(_invoices, []), do: []

  defp missing_job_invoice_numbers(invoices, tally_jobs) do
    invoices
    |> Enum.reject(&selected_tally_job(tally_jobs, &1, invoices))
    |> Enum.map(& &1["invoice_number"])
  end

  defp list_tally_jobs(_org_id, nil), do: []

  defp list_tally_jobs(org_id, source_prefix),
    do: TallyJobs.list_by_source_prefix(org_id, source_prefix)

  defp online_tally_companies(org_id, client_id) do
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
    |> TallyDevices.list_open_companies(client_id)
    |> Enum.filter(&MapSet.member?(online_device_ids, &1.device_id))
  end

  defp online_tally_company(org_id, client_id, company_id) do
    case Enum.find(online_tally_companies(org_id, client_id), &(&1.id == company_id)) do
      nil -> {:error, :not_found}
      company -> {:ok, company}
    end
  end

  defp tally_company_form(nil), do: to_form(%{"company_id" => nil}, as: :tally_company)

  defp tally_company_form(company),
    do: to_form(%{"company_id" => Integer.to_string(company.id)}, as: :tally_company)

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
                 %{source_id: Gstr1.source_id(invoice), label: invoice_label(invoice)}
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
          item = Map.put(item, :invoice_source_id, Gstr1.source_id(invoice))
          {[item | items], blocked}

        {:error, reason} ->
          {items,
           [
             %{source_id: Gstr1.source_id(invoice), label: invoice_label(invoice), reason: reason}
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

  defp posting_review_path(client, batch_ref, invoice) do
    item = URI.encode_query(%{"item" => invoice["id"] || invoice["invoice_number"]})
    "/sales-bills/#{client.id}/batch/#{batch_ref}?#{item}"
  end

  defp tally_posting(_assigns, nil), do: nil
  defp tally_posting(%{tally_company: nil}, _invoice), do: nil

  defp tally_posting(assigns, invoice) do
    org_id = assigns.current_scope.current_org.id
    company = assigns.tally_company
    choices = TallyMappings.list_ledger_choices(org_id, company.id)
    party = resolved_party(org_id, company.id, invoice)
    profile = posting_profile(org_id, company.id)

    values = %{
      "party_ledger_identity" => party && party.ledger.identity,
      "sales_ledger_identity" =>
        profile_value(profile, :sales_ledger_identity) || default_identity(choices, "Sales"),
      "cgst_ledger_identity" =>
        profile_value(profile, :cgst_ledger_identity) || default_identity(choices, "Output CGST"),
      "sgst_ledger_identity" =>
        profile_value(profile, :sgst_ledger_identity) || default_identity(choices, "Output SGST"),
      "igst_ledger_identity" =>
        profile_value(profile, :igst_ledger_identity) || default_identity(choices, "Output IGST")
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
            resolved_sales_identity(org_id, company.id, line) || values["sales_ledger_identity"],
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

  defp resolved_party(org_id, company_id, invoice) do
    case TallyMappings.resolve_party(org_id, company_id, party_identity(invoice)) do
      {:ok, match} -> match
      {:error, _reason} -> nil
    end
  end

  defp resolved_sales_identity(org_id, company_id, line) do
    case TallyMappings.resolve_sales_ledger(org_id, company_id, line) do
      {:ok, %{ledger: ledger}} -> ledger.identity
      {:error, _reason} -> nil
    end
  end

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
    case Float.parse(String.replace(value, ",", "")) do
      {number, ""} -> number > 0
      _ -> false
    end
  end

  defp positive?(_value), do: false

  defp tax_amount(invoice, head) do
    invoice
    |> Map.get("line_items", [])
    |> Enum.reduce(0.0, fn line, total -> total + number(line["#{head}_amount"]) end)
  end

  defp tax_ledger_field("cgst"), do: :cgst_ledger_identity
  defp tax_ledger_field("sgst"), do: :sgst_ledger_identity
  defp tax_ledger_field("igst"), do: :igst_ledger_identity

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", "")) do
      {number, ""} -> number
      _ -> 0.0
    end
  end

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
    invoices_by_id = Map.new(all_invoices, &{Gstr1.source_id(&1), &1})

    invoices = Enum.map(packet.invoices, &Map.fetch!(invoices_by_id, Gstr1.source_id(&1)))

    attach_reviews = fn reviews ->
      Enum.map(reviews, fn review_case ->
        %{review_case | invoice: Map.fetch!(invoices_by_id, Gstr1.source_id(review_case.invoice))}
      end)
    end

    warnings = attach_reviews.(packet.warnings)
    blocked = attach_reviews.(packet.blocked)
    excluded = Enum.map(packet.excluded, &Map.fetch!(invoices_by_id, Gstr1.source_id(&1)))

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

      {:error, _reason} ->
        socket
    end
  end

  defp find_packet_invoice(packet, source_id, fallback) do
    Enum.find(packet.all_invoices, &(Gstr1.source_id(&1) == source_id)) || fallback
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

  defp voucher_type(invoice) do
    case Gstr1.document_type(invoice) do
      "credit_note" -> "Credit Note"
      "debit_note" -> "Debit Note"
      _ -> "Sales"
    end
  end

  defp narration(invoice),
    do: invoice["narration"] || invoice["remarks"] || invoice["notes"] || "Imported from Nila"

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

  defp selected_tally_job(_jobs, nil, _all_invoices), do: nil

  defp selected_tally_job(jobs, invoice, all_invoices) do
    source_id = Gstr1.source_id(invoice)
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
    |> list_tally_jobs(socket.assigns.tally_source_prefix)
    |> invoice_frozen?(invoice, socket.assigns.packet.all_invoices)
  end

  defp selected_delivery_state(nil), do: nil

  defp selected_delivery_state(%{status: status}) when status in ["pending", "running"],
    do: :sending

  defp selected_delivery_state(%{status: "succeeded"}), do: :added
  defp selected_delivery_state(%{status: "indeterminate"}), do: :unknown
  defp selected_delivery_state(%{status: "failed"}), do: :failed

  defp invoice_delivery(invoice, jobs, packet, send_holds) do
    case selected_delivery_state(selected_tally_job(jobs, invoice, packet.all_invoices)) do
      :sending -> %{label: "Adding…", variant: "info"}
      :added -> %{label: "Added", variant: "success"}
      :unknown -> %{label: "Check in Tally", variant: "warning"}
      :failed -> %{label: "Couldn't add", variant: "error"}
      nil -> invoice_readiness_delivery(packet, invoice, send_holds)
    end
  end

  defp invoice_readiness_delivery(packet, invoice, send_holds) do
    cond do
      Enum.any?(packet.excluded, &(Gstr1.source_id(&1) == Gstr1.source_id(invoice))) ->
        %{label: "Not included", variant: "neutral"}

      Map.get(send_holds, Gstr1.source_id(invoice)) == :cannot_send ->
        %{label: "Cannot send", variant: "error"}

      invoice_case(packet.blocked, invoice) ->
        %{label: "Cannot send", variant: "error"}

      Map.get(send_holds, Gstr1.source_id(invoice)) == :needs_review or
          invoice_case(packet.warnings, invoice) ->
        %{label: "Needs review", variant: "warning"}

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

  defp selected_review(_packet, nil), do: nil

  defp selected_review(packet, invoice) do
    case invoice_case(packet.needs_review, invoice) do
      nil -> nil
      review_case -> review_presentation(review_case)
    end
  end

  defp invoice_case(_cases, nil), do: nil

  defp invoice_case(cases, invoice) do
    source_id = Gstr1.source_id(invoice)
    Enum.find(cases, &(Gstr1.source_id(&1.invoice) == source_id))
  end

  defp batch_warning_confirm([]), do: nil

  defp batch_warning_confirm(warnings) do
    count = length(warnings)

    details =
      warnings
      |> Enum.take(5)
      |> Enum.map_join("\n", fn warning ->
        number = warning.invoice["invoice_number"] || "Unnumbered invoice"
        "• #{number} — #{review_reason(warning)}"
      end)

    remainder = if count > 5, do: "\n• #{count - 5} more", else: ""

    "Heads up — #{count} #{plural(count, "invoice")} #{if(count == 1, do: "has", else: "have")} unresolved warnings.\n\n#{details}#{remainder}\n\nSend the batch to Tally anyway?"
  end

  defp review_presentation(%{invoice: invoice, issues: issues}),
    do: SalesIssuePresentation.for_invoice(invoice, issues)

  defp remainder_title(packet, jobs, send_holds) do
    if Enum.any?(jobs, &(&1.status in ["failed", "indeterminate"])) or
         map_size(send_holds) > 0 or (jobs != [] and missing_delivery_jobs?(packet, jobs)),
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

          <div
            :if={(@packet.invoices != [] and @tally_company) && @tally_jobs == []}
            id="sales-bills-tally-destination"
            class="flex items-end gap-3"
          >
            <.form
              :if={length(@tally_companies) > 1}
              for={@tally_company_form}
              id="sales-bills-tally-company-form"
              phx-change="select-tally-company"
              class="min-w-64"
            >
              <.input
                field={@tally_company_form[:company_id]}
                type="select"
                label="Tally company"
                options={Enum.map(@tally_companies, &{&1.name, &1.id})}
              />
            </.form>

            <p :if={length(@tally_companies) == 1} class="text-ink-muted text-ui pb-2">
              Sending to <span class="text-base-content font-semibold">{@tally_company.name}</span>
            </p>

            <.button
              type="button"
              id="sales-bills-send-to-tally"
              phx-click="send-to-tally"
              data-confirm={batch_warning_confirm(@packet.warnings)}
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
              phx-click="send-to-tally"
              variant="outline"
              data-confirm={batch_warning_confirm(@packet.warnings)}
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
          :if={@packet.needs_review != []}
          id="sales-bills-needs-review"
          class="space-y-related"
        >
          <h2 class="text-base-content text-h4 font-semibold">
            {length(@packet.needs_review)} {plural(length(@packet.needs_review), "invoice")} {if(
              length(@packet.needs_review) == 1,
              do: "needs",
              else: "need"
            )} review
          </h2>

          <ul class="border-base-300 divide-base-300 divide-y border-y">
            <li :for={review_case <- @packet.needs_review}>
              <.link
                id={"sales-bill-review-#{invoice_id(review_case.invoice)}"}
                patch={posting_review_path(@client, @batch_ref, review_case.invoice)}
                class="gap-block group flex items-center justify-between py-3"
              >
                <div class="min-w-0">
                  <p class="text-base-content text-ui font-mono font-medium">
                    {review_case.invoice["invoice_number"] || "Unnumbered bill"}
                  </p>
                  <p class="text-ink-muted text-ui">{review_reason(review_case)}</p>
                </div>
                <.icon name="hero-chevron-right-mini" class="text-ink-faint size-4 shrink-0" />
              </.link>
            </li>
          </ul>
        </section>

        <section
          :if={remainder(@packet, @tally_jobs) != []}
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
            rows={@packet.all_invoices}
            row_id={fn invoice -> "sales-bill-#{invoice["id"] || invoice["invoice_number"]}" end}
            row_navigate={fn invoice -> posting_review_path(@client, @batch_ref, invoice) end}
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

            <:col :let={invoice} label="Tally">
              <span id={"sales-bill-delivery-#{invoice_id(invoice)}"} class="whitespace-nowrap">
                <.badge variant={invoice_delivery(invoice, @tally_jobs, @packet, @send_holds).variant}>
                  {invoice_delivery(invoice, @tally_jobs, @packet, @send_holds).label}
                </.badge>
              </span>
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
                  label="Don’t include"
                  icon="hero-trash"
                  tone="error"
                  on_click="open-remove-invoice"
                  value={invoice_id(invoice)}
                />
                <:item
                  :if={Enum.member?(@packet.excluded, invoice)}
                  id={"sales-bill-restore-#{invoice_id(invoice)}"}
                  label="Include"
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
        :if={@removing_invoice}
        id="sales-bill-remove-dialog"
        title="Leave invoice out?"
        on_close="close-remove-invoice"
        return_focus={"#sales-bill-actions-#{invoice_id(@removing_invoice)}-trigger"}
      >
        <p class="text-base-content text-body">
          It won’t be sent to Tally. You can include it again before sending.
        </p>

        <:footer>
          <.button
            id="sales-bill-remove-cancel"
            type="button"
            variant="ghost"
            phx-click="close-remove-invoice"
          >
            Cancel
          </.button>
          <.button
            id="sales-bill-remove-confirm"
            type="button"
            variant="error"
            phx-click="remove-invoice"
          >
            Don’t include
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@selected_invoice}
        id="sales-bill-posting-review"
        title={"Invoice #{@selected_invoice["invoice_number"] || "without a number"}"}
        on_close="close-posting-review"
        variant="workbench"
        close_on_escape={is_nil(@editing_line_index) and not @evidence_open}
      >
        <:header :let={title_id}>
          <div class="grid items-center gap-3 lg:grid-cols-[1fr_auto_1fr]">
            <div class="justify-self-start">
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
            <div class="text-center">
              <h2 id={title_id} class="text-base-content text-body font-semibold">
                Invoice {@selected_invoice["invoice_number"] || "without a number"}
              </h2>
            </div>
            <div class="border-base-300 gap-related flex items-center justify-self-end border-r pr-4">
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
            if(is_nil(@editing_line_index) and not @evidence_open, do: "true", else: "false")
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
              :if={@selected_review}
              id="sales-bill-review-issues"
              class="border-warning mb-block space-y-related border-l-2 pl-3"
            >
              <p class="text-base-content text-ui font-medium">{@selected_review.summary}</p>
              <ul
                :if={@selected_review.details != []}
                class="text-ink-muted text-ui space-y-1"
              >
                <li :for={detail <- @selected_review.details}>{detail}</li>
              </ul>
            </div>

            <div class="border-base-300 mb-block flex flex-wrap items-end justify-between gap-3 border-b pb-3">
              <div>
                <div class="text-ink-subtle text-label font-semibold uppercase">
                  Proposed Tally voucher
                </div>
                <div class="text-base-content text-h4 mt-1 font-semibold">
                  {voucher_type(@selected_invoice)} invoice
                </div>
              </div>
              <div :if={@tally_company} class="text-right">
                <div class="text-ink-subtle text-label font-semibold uppercase">Company</div>
                <div class="text-base-content text-ui mt-1 font-medium">{@tally_company.name}</div>
              </div>
            </div>

            <.form
              :if={@tally_posting}
              for={@tally_posting.form}
              id="sales-bill-tally-posting-form"
              phx-submit="save-tally-posting"
              phx-change="preview-tally-posting"
              class="space-y-block"
            >
              <section class="space-y-related">
                <h3 class="text-base-content text-ui font-semibold">Voucher details</h3>
                <div class="gap-block grid sm:grid-cols-3">
                  <.input
                    id="tally-posting-invoice-number"
                    name="tally_posting[invoice][invoice_number]"
                    value={@posting_preview_invoice["invoice_number"]}
                    label="Voucher number"
                    required
                  />
                  <.input
                    id="tally-posting-invoice-date"
                    name="tally_posting[invoice][invoice_date]"
                    value={@posting_preview_invoice["invoice_date"]}
                    type="date"
                    label="Voucher date"
                    required
                  />
                  <.input
                    id="tally-posting-place-of-supply"
                    name="tally_posting[invoice][place_of_supply]"
                    value={@posting_preview_invoice["place_of_supply"]}
                    type="select"
                    label="Place of supply"
                    prompt="Select state / UT"
                    options={state_options()}
                    required
                  />
                </div>
              </section>

              <section class="border-base-300 space-y-related border-t pt-4">
                <h3 class="text-base-content text-ui font-semibold">Party</h3>
                <div class="gap-block grid sm:grid-cols-2">
                  <.input
                    id="tally-posting-buyer-name"
                    name="tally_posting[invoice][buyer_name]"
                    value={@posting_preview_invoice["buyer_name"]}
                    label="Buyer name"
                    required
                  />
                  <.input
                    id="tally-posting-buyer-gstin"
                    name="tally_posting[invoice][buyer_gstin]"
                    value={@posting_preview_invoice["buyer_gstin"]}
                    label="Buyer GSTIN"
                  />
                </div>
                <.input
                  field={@tally_posting.form[:party_ledger_identity]}
                  type="select"
                  label="Tally party ledger"
                  prompt="Select party ledger"
                  options={@tally_posting.party_choices}
                  required
                />
              </section>

              <section
                id="sales-bill-ledger-allocations"
                class="border-base-300 space-y-related border-t pt-4"
              >
                <div class="flex items-baseline justify-between gap-3">
                  <h3 class="text-base-content text-ui font-semibold">Ledger allocations</h3>
                  <span class="text-ink-subtle text-ui">
                    {length(@tally_posting.line_rows)} {plural(
                      length(@tally_posting.line_rows),
                      "line"
                    )}
                  </span>
                </div>
                <.data_table
                  id="sales-bill-posting-lines"
                  rows={@tally_posting.line_rows}
                  row_id={fn row -> "sales-bill-posting-line-#{row.index}" end}
                  mode="review"
                  min_width="min-w-[760px]"
                >
                  <:col :let={row} label="Invoice line" row_header class="min-w-72">
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
                    <div class="space-y-1 tabular-nums">
                      <span class="text-base-content text-ui block font-medium">
                        {rupees(row.line["taxable_value"])}
                      </span>
                      <span class="text-ink-muted text-ui block">Taxable</span>
                    </div>
                    <.input
                      type="hidden"
                      name={"tally_posting[invoice][line_items][#{row.index}][taxable_value]"}
                      value={row.line["taxable_value"]}
                    />
                  </:col>
                  <:col :let={row} label="GST" class="min-w-36">
                    <div class="space-y-related">
                      <span :if={row.tax_rows == []} class="text-ink-muted text-ui">—</span>
                      <div :for={tax <- row.tax_rows} class="text-ui tabular-nums">
                        <span class="text-base-content block font-medium">
                          {tax.label} {working_number(tax.rate)}%
                        </span>
                        <span class="text-ink-muted">{rupees(tax.amount)}</span>
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
                  <:col :let={row} label="Tally sales ledger" class="min-w-48 align-middle">
                    <.input
                      id={"tally-posting-line-sales-ledger-#{row.index}"}
                      name={"tally_posting[line_sales_ledger_identities][#{row.index}]"}
                      value={row.sales_ledger_identity}
                      type="select"
                      prompt="Select ledger"
                      options={@tally_posting.sales_choices}
                      aria-label={"Line #{row.index + 1} Tally sales ledger"}
                      required
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
                      disabled={invoice_frozen?(@tally_jobs, @selected_invoice, @packet.all_invoices)}
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

              <section class="border-base-300 space-y-related border-t pt-4">
                <h3 class="text-base-content text-ui font-semibold">Tax posting</h3>
                <div
                  :for={row <- @tally_posting.tax_rows}
                  id={"sales-bill-tax-row-#{row.head}"}
                  class="gap-block grid items-end sm:grid-cols-[minmax(0,1fr)_auto]"
                >
                  <.input
                    field={@tally_posting.form[row.field]}
                    type="select"
                    label={"#{row.label} ledger"}
                    prompt={"Select #{row.label} ledger"}
                    options={@tally_posting.tax_choices}
                    required
                  />
                  <div class="text-ui pb-2 text-right tabular-nums">
                    <span class="text-ink-subtle block">Amount</span>
                    <span class="text-base-content font-medium">{rupees(row.amount)}</span>
                  </div>
                </div>
              </section>

              <section class="border-base-300 border-t pt-4">
                <.input
                  id="tally-posting-narration"
                  name="tally_posting[invoice][narration]"
                  value={narration(@posting_preview_invoice)}
                  type="textarea"
                  label="Narration"
                  rows="3"
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

              <div class="bg-base-100 border-base-300 sticky bottom-0 border-t py-4">
                <div class="gap-block flex flex-col lg:flex-row lg:items-end lg:justify-between">
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
                      Save & Close
                    </.button>
                  </div>
                </div>
              </div>
            </.form>

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
                <div class="gap-related flex justify-end">
                  <.button type="button" variant="ghost" phx-click="close-posting-line">
                    Cancel
                  </.button>
                  <.button type="submit" form="sales-bill-line-edit-form">
                    Save changes
                  </.button>
                </div>
              </:footer>
            </.modal>

            <.callout
              :if={is_nil(@tally_posting)}
              kind="warning"
              size="compact"
              title="Tally company not connected"
            >
              Open the matching company in TallyPrime and sync its masters to choose posting ledgers.
            </.callout>
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
