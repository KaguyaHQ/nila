defmodule Nila.Business.Invoicing do
  @moduledoc "Domestic taxable goods and service billing for an authorized business client."
  import Ecto.Query
  import Ecto.Changeset
  alias Nila.Business.{Customer, CustomerAddress, Invoice, Profile, Service}
  alias Nila.Clients.Client
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.{Derivation, Month, Processing}
  alias Nila.{Repo, Storage}

  # Positive rate values accepted by the existing GSTR-1 output boundary.
  @gst_rates ~w(0.1 0.25 1 1.5 3 5 6 7.5 12 18 28 40)
  @max_brand_image_bytes 512_000

  def get_profile(%Client{} = client) do
    Repo.get_by(Profile, client_id: client.id) ||
      %Profile{
        client_id: client.id,
        legal_name: client.name,
        address: client.address,
        state_code: Nila.Gst.StateCodes.from_gstin(client.gstin)
      }
  end

  def save_profile(%Client{} = client, attrs) do
    profile = get_profile(client)
    changeset = Profile.changeset(profile, attrs)

    changeset =
      if get_field(changeset, :state_code) == Nila.Gst.StateCodes.from_gstin(client.gstin),
        do: changeset,
        else: add_error(changeset, :state_code, "must match your GST registration")

    Repo.insert_or_update(changeset)
  end

  def quotation_numbering(%Client{} = client) do
    numbering(client, "quotation")
  end

  def invoice_numbering(%Client{} = client) do
    numbering(client, "invoice")
  end

  defp numbering(client, type) do
    year = financial_year(Date.utc_today())
    profile = get_profile(client)

    next_number =
      case Repo.query!(
             "SELECT last_number FROM business_invoice_counters WHERE client_id = $1 AND financial_year = $2 AND document_type = $3",
             [client.id, year, type]
           ).rows do
        [[last]] -> last + 1
        [] -> initial_sequence(client, year, type, profile)
      end

    numbering = %{
      financial_year: year,
      style:
        if(type == "invoice",
          do: profile.invoice_number_style,
          else: profile.quotation_number_style
        ),
      next_number: next_number,
      editable: type == "quotation" or not issued_in_year?(client, year, type)
    }

    if type == "quotation" do
      Map.put(
        numbering,
        :next_quotation_number,
        format_quotation_number(profile, year, next_number)
      )
    else
      numbering
    end
  end

  def configure_quotation_numbering(%Client{} = client, attrs) do
    attrs = string_keys(attrs)
    year = financial_year(Date.utc_today())

    with {:ok, config} <- parse_quotation_number(attrs["next_quotation_number"], year) do
      Repo.transact(fn ->
        current =
          Repo.one!(
            from c in Client,
              where: c.id == ^client.id and c.org_id == ^client.org_id,
              lock: "FOR UPDATE"
          )

        with %Profile{} = profile <- Repo.get_by(Profile, client_id: current.id),
             false <-
               Repo.exists?(
                 from i in Invoice,
                   where:
                     i.client_id == ^current.id and i.number == ^attrs["next_quotation_number"]
               ),
             {:ok, _profile} <-
               profile
               |> change(%{
                 quotation_number_style: config.style,
                 quotation_number_prefix: config.prefix,
                 quotation_number_min_digits: config.min_digits
               })
               |> Repo.update() do
          Repo.query!(
            "INSERT INTO business_invoice_counters (client_id, financial_year, document_type, last_number) VALUES ($1, $2, 'quotation', $3) ON CONFLICT (client_id, financial_year, document_type) DO UPDATE SET last_number = EXCLUDED.last_number",
            [current.id, year, config.next_number - 1]
          )

          {:ok, quotation_numbering(current)}
        else
          nil -> {:error, :profile_incomplete}
          true -> {:error, :number_already_used}
          error -> error
        end
      end)
    end
  end

  def configure_invoice_numbering(%Client{} = client, attrs) do
    configure_numbering(client, attrs, "invoice")
  end

  defp configure_numbering(client, attrs, type) do
    attrs = string_keys(attrs)
    style = attrs["style"]
    next_number = parse_number(attrs["next_number"])

    if style in ~w(nila serial_fy) and is_integer(next_number) and
         next_number in 1..999_999 do
      Repo.transact(fn ->
        current =
          Repo.one!(
            from c in Client,
              where: c.id == ^client.id and c.org_id == ^client.org_id,
              lock: "FOR UPDATE"
          )

        year = financial_year(Date.utc_today())

        field = if(type == "invoice", do: :invoice_number_style, else: :quotation_number_style)

        with false <- issued_in_year?(current, year, type),
             %Profile{} = profile <- Repo.get_by(Profile, client_id: current.id),
             {:ok, _profile} <- profile |> change(%{field => style}) |> Repo.update() do
          Repo.query!(
            "INSERT INTO business_invoice_counters (client_id, financial_year, document_type, last_number) VALUES ($1, $2, $3, $4) ON CONFLICT (client_id, financial_year, document_type) DO UPDATE SET last_number = EXCLUDED.last_number",
            [current.id, year, type, next_number - 1]
          )

          {:ok, numbering(current, type)}
        else
          true -> {:error, :numbering_started}
          nil -> {:error, :profile_incomplete}
          error -> error
        end
      end)
    else
      {:error, :invalid_numbering}
    end
  end

  def save_brand_asset(%Client{} = client, kind, bytes)
      when kind in ["logo", "signature"] and is_binary(bytes) do
    with {:ok, extension, content_type} <- brand_image_type(bytes),
         %Profile{} = profile <- Repo.get_by(Profile, client_id: client.id),
         key <-
           "orgs/#{client.org_id}/clients/#{client.id}/business/brand/#{kind}/#{Ecto.UUID.generate()}.#{extension}",
         {:ok, _} <- Storage.put(key, bytes, content_type: content_type) do
      field = if kind == "logo", do: :logo_key, else: :signature_key
      profile |> change(%{field => key}) |> Repo.update()
    else
      nil -> {:error, :profile_incomplete}
      error -> error
    end
  end

  def save_brand_asset(%Client{}, _, _), do: {:error, :invalid_asset}

  def get_brand_asset(%Client{} = client, kind) when kind in ["logo", "signature"] do
    profile = get_profile(client)
    key = if kind == "logo", do: profile.logo_key, else: profile.signature_key

    if key do
      with {:ok, bytes} <- Storage.get(key) do
        {:ok, bytes, if(String.ends_with?(key, ".png"), do: "image/png", else: "image/jpeg")}
      end
    else
      {:error, :not_found}
    end
  end

  def get_brand_asset(%Client{}, _), do: {:error, :not_found}

  def remove_brand_asset(%Client{} = client, kind) when kind in ["logo", "signature"] do
    case Repo.get_by(Profile, client_id: client.id) do
      %Profile{} = profile ->
        field = if kind == "logo", do: :logo_key, else: :signature_key
        profile |> change(%{field => nil}) |> Repo.update()

      nil ->
        {:error, :profile_incomplete}
    end
  end

  def remove_brand_asset(%Client{}, _), do: {:error, :not_found}

  defp brand_image_type(bytes) when byte_size(bytes) <= @max_brand_image_bytes do
    case bytes do
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", width::32, height::32, _::binary>>
      when width > 0 and height > 0 ->
        if :binary.part(bytes, byte_size(bytes) - 12, 12) ==
             <<0, 0, 0, 0, "IEND", 174, 66, 96, 130>>,
           do: {:ok, "png", "image/png"},
           else: {:error, :invalid_asset}

      <<255, 216, 255, _::binary>> when byte_size(bytes) > 100 ->
        if :binary.part(bytes, byte_size(bytes) - 2, 2) == <<255, 217>>,
          do: {:ok, "jpg", "image/jpeg"},
          else: {:error, :invalid_asset}

      _ ->
        {:error, :invalid_asset}
    end
  end

  defp brand_image_type(_), do: {:error, :invalid_asset}

  def list_services(%Client{id: id}),
    do:
      Repo.all(
        from s in Service, where: s.client_id == ^id, order_by: [asc: s.description, asc: s.id]
      )

  def create_service(%Client{id: id}, attrs),
    do: %Service{client_id: id} |> Service.changeset(attrs) |> Repo.insert()

  def update_service(%Client{id: client_id}, id, attrs) do
    with {:ok, service} <- Repo.fetch_by(Service, id: id, client_id: client_id),
         do: service |> Service.changeset(attrs) |> Repo.update()
  end

  def delete_service(%Client{id: client_id}, id) do
    with {:ok, service} <- Repo.fetch_by(Service, id: id, client_id: client_id),
         do: Repo.delete(service)
  end

  def list_customers(%Client{id: id}),
    do:
      Repo.all(from c in Customer, where: c.client_id == ^id, order_by: [asc: c.name, asc: c.id])

  def create_customer(%Client{id: id}, attrs) do
    Repo.transact(fn ->
      with {:ok, customer} <-
             %Customer{client_id: id} |> Customer.changeset(attrs) |> Repo.insert(),
           {:ok, _address} <-
             %CustomerAddress{client_id: id, customer_id: customer.id}
             |> CustomerAddress.changeset(%{
               label: "Primary address",
               address: customer.address,
               state_code: customer.state_code,
               gstin: customer.gstin,
               usage: "either",
               is_primary_billing: true,
               is_primary_shipping: true
             })
             |> Repo.insert() do
        {:ok, customer}
      end
    end)
  end

  def update_customer(%Client{} = client, id, attrs) do
    Repo.transact(fn ->
      with {:ok, customer} <- locked_customer(client, id),
           {:ok, customer} <- customer |> Customer.changeset(attrs) |> Repo.update(),
           %CustomerAddress{} = primary <- primary_billing_address(customer),
           {:ok, _address} <-
             primary
             |> CustomerAddress.changeset(%{
               address: customer.address,
               state_code: customer.state_code,
               gstin: customer.gstin
             })
             |> Repo.update() do
        {:ok, customer}
      end
    end)
  end

  def list_customer_addresses(%Client{id: id}) do
    Repo.all(
      from a in CustomerAddress,
        where: a.client_id == ^id,
        order_by: [asc: a.customer_id, desc: a.is_primary_billing, asc: a.label, asc: a.id]
    )
  end

  def create_customer_address(%Client{} = client, customer_id, attrs) do
    Repo.transact(fn ->
      with {:ok, customer} <- locked_customer(client, customer_id) do
        address = %CustomerAddress{client_id: client.id, customer_id: customer.id}
        save_customer_address(client, customer, address, attrs, :insert)
      end
    end)
  end

  def update_customer_address(%Client{} = client, customer_id, id, attrs) do
    Repo.transact(fn ->
      with {:ok, customer} <- locked_customer(client, customer_id),
           {:ok, address} <-
             Repo.fetch_by(CustomerAddress,
               id: id,
               customer_id: customer.id,
               client_id: client.id
             ) do
        save_customer_address(client, customer, address, attrs, :update)
      end
    end)
  end

  defp save_customer_address(client, customer, address, attrs, action) do
    changeset = CustomerAddress.changeset(address, attrs)

    with {:ok, candidate} <- Ecto.Changeset.apply_action(changeset, action),
         :ok <- primary_address_change_allowed(address, candidate) do
      if candidate.is_primary_billing do
        from(a in CustomerAddress,
          where:
            a.customer_id == ^customer.id and a.client_id == ^client.id and
              a.id != ^(address.id || 0)
        )
        |> Repo.update_all(set: [is_primary_billing: false])
      end

      if candidate.is_primary_shipping do
        from(a in CustomerAddress,
          where:
            a.customer_id == ^customer.id and a.client_id == ^client.id and
              a.id != ^(address.id || 0)
        )
        |> Repo.update_all(set: [is_primary_shipping: false])
      end

      with {:ok, saved} <-
             if(action == :insert, do: Repo.insert(changeset), else: Repo.update(changeset)),
           {:ok, _customer} <- maybe_sync_primary_customer(customer, saved) do
        {:ok, saved}
      end
    end
  end

  defp primary_address_change_allowed(%CustomerAddress{id: nil}, _candidate), do: :ok

  defp primary_address_change_allowed(current, candidate) do
    cond do
      current.is_primary_billing and not candidate.is_primary_billing ->
        {:error, :primary_billing_required}

      current.is_primary_shipping and not candidate.is_primary_shipping ->
        {:error, :primary_shipping_required}

      true ->
        :ok
    end
  end

  defp maybe_sync_primary_customer(customer, %CustomerAddress{is_primary_billing: true} = address) do
    customer
    |> Customer.changeset(%{
      address: address.address,
      state_code: address.state_code,
      gstin: address.gstin
    })
    |> Repo.update()
  end

  defp maybe_sync_primary_customer(customer, _), do: {:ok, customer}

  defp primary_billing_address(customer) do
    Repo.get_by(CustomerAddress,
      customer_id: customer.id,
      client_id: customer.client_id,
      is_primary_billing: true
    )
  end

  defp locked_customer(client, id) do
    case Repo.one(
           from c in Customer,
             where: c.id == ^id and c.client_id == ^client.id,
             lock: "FOR UPDATE"
         ) do
      %Customer{} = customer -> {:ok, customer}
      nil -> {:error, :not_found}
    end
  end

  def list_invoices(%Client{id: id}),
    do:
      Repo.all(
        from i in Invoice,
          where: i.client_id == ^id,
          order_by: [desc: i.invoice_date, desc: i.id],
          preload: [:customer]
      )

  def get_invoice(%Client{id: client_id}, id) do
    with {:ok, invoice} <- Repo.fetch_by(Invoice, client_id: client_id, id: id),
         do: {:ok, Repo.preload(invoice, :customer)}
  end

  def preview(%Client{} = client, attrs, opts \\ []) do
    with {:ok, customer} <- customer_for(client, attrs),
         {:ok, original} <- original_for(client, attrs),
         :ok <- matching_original(customer, original),
         {:ok, invoice} <-
           %Invoice{
             client_id: client.id,
             customer_id: customer.id,
             original_invoice_id: original && original.id,
             document_type: document_type(attrs, original)
           }
           |> Invoice.draft_changeset(attrs)
           |> validate_addresses(client, customer)
           |> validate_lines(client)
           |> apply_action(:validate),
         profile <- get_profile(client),
         {:ok, lines} <-
           calculate_lines(invoice.lines, profile.state_code == invoice.place_of_supply) do
      client
      |> snapshot(profile, customer, invoice, lines, "DRAFT", original)
      |> Map.put("draft", true)
      |> render(opts)
    end
  end

  def calculate(%Client{} = client, %{"lines" => lines, "place_of_supply" => state})
      when is_list(lines) and length(lines) in 1..100 do
    if state in Enum.map(Nila.Gst.StateCodes.all(), &Nila.Gst.StateCodes.code_for/1) do
      intra? = Nila.Gst.StateCodes.from_gstin(client.gstin) == state

      lines
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case calculate_amounts(line, intra?) do
          {:ok, calculated} -> {:cont, {:ok, [calculated | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, calculated} ->
          calculated = Enum.reverse(calculated)
          totals = line_totals(calculated)

          {:ok,
           %{
             lines: calculated,
             totals: totals,
             total_in_words: Nila.Formatters.amount_in_words(totals["total_paise"])
           }}

        error ->
          error
      end
    else
      {:error, :invalid_attrs}
    end
  end

  def calculate(%Client{}, _), do: {:error, :invalid_attrs}

  def save_draft(%Client{} = client, actor_id, attrs) do
    with {:ok, customer} <- customer_for(client, attrs),
         {:ok, original} <- original_for(client, attrs),
         :ok <- matching_original(customer, original) do
      %Invoice{
        client_id: client.id,
        customer_id: customer.id,
        created_by_id: actor_id,
        original_invoice_id: original && original.id,
        document_type: document_type(attrs, original)
      }
      |> Invoice.draft_changeset(attrs)
      |> validate_addresses(client, customer)
      |> validate_lines(client)
      |> Repo.insert()
    end
  end

  def update_draft(%Client{} = client, id, _actor_id, attrs) do
    Repo.transact(fn -> update_draft_in_transaction(client, id, attrs) end)
  end

  def delete_draft(%Client{} = client, id) do
    Repo.transact(fn ->
      with {:ok, invoice} <- locked_invoice(client, id),
           :ok <- draft?(invoice),
           false <- draft_referenced?(client, invoice.id) do
        Repo.delete(invoice)
      else
        true -> {:error, :draft_in_use}
        error -> error
      end
    end)
  end

  @doc "Copies an ordinary invoice or quotation into a new, unnumbered draft."
  def copy_to_draft(%Client{} = client, id, actor_id) do
    with {:ok, source} <- get_invoice(client, id),
         true <- source.document_type in ["invoice", "quotation"] do
      today = Date.utc_today()

      attrs =
        source
        |> Map.take([
          :customer_id,
          :billing_address_id,
          :shipping_address_id,
          :place_of_supply,
          :lines,
          :notes,
          :delivery_address,
          :delivery_state_code,
          :subject
        ])
        |> Map.put(:document_type, source.document_type)
        |> Map.put(:invoice_date, today)
        |> Map.put(:due_date, nil)
        |> Map.put(
          :valid_until,
          if(
            (source.document_type == "quotation" and source.valid_until) &&
              Date.compare(source.valid_until, today) != :lt,
            do: source.valid_until,
            else: nil
          )
        )
        |> string_keys()

      save_draft(client, actor_id, attrs)
    else
      false -> {:error, :invalid_copy_source}
      error -> error
    end
  end

  @doc "Cancels an issued ordinary invoice while retaining its number and evidence."
  def cancel_invoice(%Client{} = client, id, actor_id, reason) when is_binary(reason) do
    reason = String.trim(reason)

    Repo.transact(
      fn ->
        current_client =
          Repo.one!(
            from c in Client,
              where: c.id == ^client.id and c.org_id == ^client.org_id,
              lock: "FOR UPDATE"
          )

        with {:ok, invoice} <- locked_invoice(current_client, id) do
          cancel_issued_invoice(current_client, invoice, actor_id, reason)
        end
      end,
      timeout: 60_000
    )
  end

  def cancel_invoice(%Client{}, _id, _actor_id, _reason),
    do: {:error, :cancellation_reason_required}

  defp cancel_issued_invoice(
         _client,
         %Invoice{status: "cancelled"} = invoice,
         _actor_id,
         _reason
       ),
       do: {:ok, Repo.preload(invoice, :customer)}

  defp cancel_issued_invoice(client, %Invoice{} = invoice, actor_id, reason) do
    with :ok <- cancellable_invoice?(invoice),
         :ok <- cancellation_reason_valid?(reason),
         :ok <- no_issued_credit_notes(client, invoice.id),
         :ok <- open_month(client, invoice.invoice_date),
         {:ok, dump} <-
           Repo.fetch_one(
             from d in Dump,
               where: d.id == ^invoice.dump_id and d.client_id == ^client.id,
               lock: "FOR UPDATE"
           ),
         [facts] <- dump.invoices do
      cancelled_facts = Map.put(facts, "document_status", "cancelled")

      dump =
        dump
        |> Dump.changeset(%{invoices: [cancelled_facts]})
        |> Repo.update!()

      :ok = Derivation.refresh_in_transaction(dump)

      invoice
      |> change(
        status: "cancelled",
        cancelled_at: DateTime.utc_now(),
        cancelled_by_id: actor_id,
        cancellation_reason: reason
      )
      |> Repo.update()
      |> case do
        {:ok, cancelled} -> {:ok, Repo.preload(cancelled, :customer)}
        error -> error
      end
    else
      [] -> {:error, :sales_evidence_missing}
      [_ | _] -> {:error, :sales_evidence_invalid}
      error -> error
    end
  end

  defp cancellable_invoice?(%Invoice{document_type: "invoice", status: "issued", dump_id: id})
       when not is_nil(id),
       do: :ok

  defp cancellable_invoice?(%Invoice{document_type: "quotation"}),
    do: {:error, :quotation_cannot_be_cancelled}

  defp cancellable_invoice?(%Invoice{document_type: "credit_note"}),
    do: {:error, :credit_note_cannot_be_cancelled}

  defp cancellable_invoice?(%Invoice{status: "draft"}), do: {:error, :invoice_not_issued}
  defp cancellable_invoice?(_), do: {:error, :invoice_cannot_be_cancelled}

  defp cancellation_reason_valid?(reason) do
    if String.length(reason) in 1..500,
      do: :ok,
      else: {:error, :cancellation_reason_required}
  end

  defp no_issued_credit_notes(client, invoice_id) do
    if Repo.exists?(
         from i in Invoice,
           where:
             i.client_id == ^client.id and i.document_type == "credit_note" and
               i.original_invoice_id == ^invoice_id and i.status == "issued"
       ),
       do: {:error, :issued_credit_notes_exist},
       else: :ok
  end

  defp draft_referenced?(client, invoice_id) do
    Repo.exists?(
      from i in Invoice,
        where:
          i.client_id == ^client.id and
            (i.original_invoice_id == ^invoice_id or i.converted_invoice_id == ^invoice_id or
               i.revised_from_id == ^invoice_id)
    )
  end

  defp update_draft_in_transaction(client, id, attrs) do
    with {:ok, invoice} <- locked_invoice(client, id),
         :ok <- draft?(invoice),
         {:ok, customer} <-
           customer_for(
             client,
             Map.put_new(string_keys(attrs), "customer_id", invoice.customer_id)
           ),
         :ok <-
           matching_original(
             customer,
             invoice.original_invoice_id && Repo.get!(Invoice, invoice.original_invoice_id)
           ) do
      invoice
      |> Invoice.draft_changeset(attrs)
      |> put_change(:customer_id, customer.id)
      |> validate_addresses(client, customer)
      |> validate_lines(client)
      |> Repo.update()
    end
  end

  def finalize_quotation(%Client{} = client, actor_id, attrs, id \\ nil, opts \\ []) do
    attrs = Map.put(string_keys(attrs), "document_type", "quotation")

    Repo.transact(
      fn ->
        current_client =
          Repo.one!(
            from c in Client,
              where: c.id == ^client.id and c.org_id == ^client.org_id,
              lock: "FOR UPDATE"
          )

        with {:ok, draft} <-
               if(id,
                 do: update_quotation_draft_in_transaction(current_client, id, attrs),
                 else: save_draft(current_client, actor_id, attrs)
               ),
             do: issue_in_transaction(current_client, draft.id, actor_id, opts)
      end,
      timeout: 60_000
    )
  end

  @doc "Finalizes a migrated quotation under its original number without changing live numbering."
  def finalize_imported_quotation(%Client{} = client, actor_id, attrs, number, opts \\ [])
      when is_binary(number) do
    number = String.trim(number)
    attrs = Map.put(string_keys(attrs), "document_type", "quotation")

    if number == "" or String.length(number) > 100 do
      {:error, :invalid_imported_number}
    else
      Repo.transact(
        fn ->
          current_client =
            Repo.one!(
              from c in Client,
                where: c.id == ^client.id and c.org_id == ^client.org_id,
                lock: "FOR UPDATE"
            )

          with false <-
                 Repo.exists?(
                   from i in Invoice,
                     where: i.client_id == ^current_client.id and i.number == ^number
                 ),
               {:ok, draft} <- save_draft(current_client, actor_id, attrs),
               do:
                 issue_in_transaction(
                   current_client,
                   draft.id,
                   actor_id,
                   Keyword.put(opts, :imported_number, number)
                 )
        end,
        timeout: 60_000
      )
      |> case do
        {:ok, true} -> {:error, :number_already_used}
        result -> result
      end
    end
  end

  def finalize_invoice(%Client{} = client, actor_id, attrs, id \\ nil, opts \\ []) do
    attrs = string_keys(attrs)
    type = if(attrs["original_invoice_id"], do: "credit_note", else: "invoice")
    attrs = Map.put(attrs, "document_type", type)

    Repo.transact(
      fn ->
        current_client =
          Repo.one!(
            from c in Client,
              where: c.id == ^client.id and c.org_id == ^client.org_id,
              lock: "FOR UPDATE"
          )

        with {:ok, draft} <-
               if(id,
                 do: update_billing_draft_in_transaction(current_client, id, attrs, type),
                 else: save_draft(current_client, actor_id, attrs)
               ),
             do: issue_in_transaction(current_client, draft.id, actor_id, opts)
      end,
      timeout: 60_000
    )
  end

  defp update_billing_draft_in_transaction(client, id, attrs, type) do
    case locked_invoice(client, id) do
      {:ok, %Invoice{document_type: ^type}} -> update_draft_in_transaction(client, id, attrs)
      {:ok, _} -> {:error, :invalid_document_type}
      error -> error
    end
  end

  defp update_quotation_draft_in_transaction(client, id, attrs) do
    case locked_invoice(client, id) do
      {:ok, %Invoice{document_type: "quotation"}} ->
        update_draft_in_transaction(client, id, attrs)

      {:ok, _} ->
        {:error, :invalid_document_type}

      error ->
        error
    end
  end

  def issue(%Client{} = client, id, actor_id, opts \\ []) do
    # Client lock also serializes creation of the first sales month and its numbering row.
    # Keep lock order client -> invoice -> sales month for all business issuance.
    Repo.transact(fn -> issue_in_transaction(client, id, actor_id, opts) end, timeout: 60_000)
  end

  defp issue_in_transaction(client, id, actor_id, opts) do
    current_client =
      Repo.one!(
        from c in Client,
          where: c.id == ^client.id and c.org_id == ^client.org_id,
          lock: "FOR UPDATE"
      )

    with {:ok, invoice} <- locked_invoice(current_client, id),
         :ok <- draft?(invoice),
         {:ok, profile} <- ready_profile(current_client, invoice),
         {:ok, customer} <-
           Repo.fetch_by(Customer, id: invoice.customer_id, client_id: current_client.id),
         {:ok, invoice} <-
           invoice
           |> Invoice.draft_changeset(%{})
           |> validate_addresses(current_client, customer)
           |> Ecto.Changeset.apply_action(:validate),
         :ok <- open_document_month(current_client, invoice),
         {:ok, lines} <-
           calculate_lines(invoice.lines, profile.state_code == invoice.place_of_supply),
         {:ok, original} <- issue_original(current_client, invoice, lines),
         number <- opts[:imported_number] || next_number(current_client, invoice, profile),
         snapshot <- snapshot(current_client, profile, customer, invoice, lines, number, original),
         {:ok, bytes} <- render(snapshot, Keyword.delete(opts, :imported_number)),
         key <-
           "orgs/#{current_client.org_id}/clients/#{current_client.id}/business/#{invoice.id}/#{Ecto.UUID.generate()}.pdf",
         {:ok, _stored} <- Storage.put(key, bytes, content_type: "application/pdf"),
         {:ok, issued} <-
           persist_issue(current_client, invoice, actor_id, snapshot, key, bytes) do
      {:ok, Repo.preload(issued, :customer)}
    end
  end

  # Like Bigcapital estimates, approval/rejection is only available after finalizing,
  # and conversion retains a link to the created invoice. Locking makes retries safe.
  def quotation_status(%Client{} = client, id, actor_id, status) when is_binary(status),
    do: quotation_status(client, id, actor_id, %{"status" => status})

  def quotation_status(%Client{} = client, id, _actor_id, %{"status" => status} = attrs)
      when status in ["awaiting_po", "accepted", "declined"] do
    Repo.transact(fn ->
      with {:ok, quote} <- locked_invoice(client, id),
           :ok <- quotation_transition(quote, status) do
        quote
        |> quotation_status_changeset(status, attrs)
        |> Repo.update()
      end
    end)
  end

  def quotation_status(%Client{}, _id, _actor_id, _status),
    do: {:error, :invalid_quotation_status}

  def convert_quotation(%Client{} = client, id, actor_id) do
    Repo.transact(fn ->
      with {:ok, quote} <- locked_invoice(client, id) do
        case quote do
          %Invoice{
            document_type: "quotation",
            status: "converted",
            converted_invoice_id: invoice_id
          } ->
            with {:ok, invoice} <- get_invoice(client, invoice_id),
                 do: {:ok, %{invoice: invoice, quotation: quote}}

          %Invoice{document_type: "quotation", status: "accepted"} ->
            attrs =
              quote
              |> Map.take([
                :customer_id,
                :billing_address_id,
                :shipping_address_id,
                :place_of_supply,
                :lines,
                :notes,
                :purchase_order_number,
                :purchase_order_date,
                :delivery_address,
                :delivery_state_code,
                :subject
              ])
              |> Map.put(:invoice_date, Date.utc_today())
              |> string_keys()

            with {:ok, invoice} <- save_draft(client, actor_id, attrs) do
              quotation =
                quote
                |> change(status: "converted", converted_invoice_id: invoice.id)
                |> Repo.update!()

              {:ok, %{invoice: invoice, quotation: quotation}}
            end

          _ ->
            {:error, :quotation_not_accepted}
        end
      end
    end)
  end

  defp quotation_status_changeset(quote, "awaiting_po", attrs) do
    quote
    |> cast(attrs, [:sent_on])
    |> validate_required([:sent_on])
    |> put_change(:status, "awaiting_po")
  end

  defp quotation_status_changeset(quote, "accepted", attrs) do
    quote
    |> cast(attrs, [:purchase_order_number, :purchase_order_date])
    |> validate_length(:purchase_order_number, max: 100)
    |> put_change(:status, "accepted")
  end

  defp quotation_status_changeset(quote, "declined", _attrs),
    do: change(quote, status: "declined")

  defp quotation_transition(
         %Invoice{document_type: "quotation", status: source},
         target
       )
       when source in ["issued", "awaiting_po", "accepted", "declined"] and
              target in ["awaiting_po", "accepted", "declined"],
       do: :ok

  defp quotation_transition(_, _), do: {:error, :invalid_quotation_status}

  def revise_quotation(%Client{} = client, id, actor_id) do
    Repo.transact(fn ->
      with {:ok, quote} <- locked_invoice(client, id),
           true <- quote.document_type == "quotation" and quote.status != "draft" do
        today = Date.utc_today()

        attrs =
          quote
          |> Map.take([
            :customer_id,
            :billing_address_id,
            :shipping_address_id,
            :place_of_supply,
            :lines,
            :notes,
            :purchase_order_number,
            :delivery_address,
            :delivery_state_code,
            :subject
          ])
          |> Map.put(:document_type, "quotation")
          |> Map.put(:invoice_date, today)
          |> Map.put(
            :valid_until,
            if(quote.valid_until && Date.compare(quote.valid_until, today) != :lt,
              do: quote.valid_until,
              else: nil
            )
          )
          |> string_keys()

        with {:ok, draft} <- save_draft(client, actor_id, attrs),
             {:ok, revised} <-
               draft |> change(revised_from_id: quote.id) |> Repo.update() do
          {:ok, Repo.preload(revised, :customer)}
        end
      else
        false -> {:error, :invalid_quotation_status}
        error -> error
      end
    end)
  end

  def download(%Client{} = client, id) do
    with {:ok, %Invoice{status: status, pdf_key: key}}
         when status in [
                "issued",
                "awaiting_po",
                "accepted",
                "declined",
                "converted",
                "cancelled"
              ] <-
           get_invoice(client, id),
         do: Storage.get(key),
         else: (_ -> {:error, :not_issued})
  end

  defp persist_issue(
         _client,
         %Invoice{document_type: "quotation"} = invoice,
         actor_id,
         snapshot,
         key,
         bytes
       ) do
    invoice
    |> change(
      status: "issued",
      number: snapshot["number"],
      snapshot: snapshot,
      totals: snapshot["totals"],
      pdf_key: key,
      issued_by_id: actor_id,
      pdf_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      issued_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  defp persist_issue(client, invoice, actor_id, snapshot, key, bytes) do
    period = Calendar.strftime(invoice.invoice_date, "%Y-%m")

    with {:ok, dump} <-
           Dumps.record(
             %{org_id: client.org_id, client_id: client.id, brought_in_by_id: actor_id},
             %{
               kind: "sales",
               period: period,
               status: "extracted",
               file_keys: [key],
               meta: %{
                 "sales_batch" => true,
                 "original_name" => "#{String.replace(snapshot["number"], "/", "-")}.pdf",
                 "business_invoice_id" => invoice.id
               }
             }
           ) do
      facts = sales_facts(snapshot) |> Map.put("id", Processing.source_id(dump, 1))
      dump = dump |> Dump.changeset(%{invoices: [facts]}) |> Repo.update!()
      :ok = Derivation.refresh_in_transaction(dump)

      invoice
      |> change(
        status: "issued",
        number: snapshot["number"],
        snapshot: snapshot,
        totals: snapshot["totals"],
        pdf_key: key,
        dump_id: dump.id,
        issued_by_id: actor_id,
        pdf_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        issued_at: DateTime.utc_now()
      )
      |> Repo.update()
    end
  end

  defp locked_invoice(client, id),
    do:
      Repo.fetch_one(
        from i in Invoice, where: i.client_id == ^client.id and i.id == ^id, lock: "FOR UPDATE"
      )

  defp draft?(%Invoice{status: "draft"}), do: :ok
  defp draft?(_), do: {:error, :already_issued}

  defp ready_profile(client, invoice) do
    profile = get_profile(client)

    cond do
      not Nila.Gstin.valid?(client.gstin) ->
        {:error, :seller_gstin_required}

      invoice.document_type == "quotation" and not Profile.changeset(profile, %{}).valid? ->
        {:error, :profile_incomplete}

      invoice.document_type != "quotation" and
          (is_nil(profile.id) or not Profile.changeset(profile, %{}).valid?) ->
        {:error, :profile_incomplete}

      profile.state_code != Nila.Gst.StateCodes.from_gstin(client.gstin) ->
        {:error, :seller_state_mismatch}

      true ->
        {:ok, profile}
    end
  end

  defp validate_addresses(changeset, client, customer) do
    changeset =
      if get_field(changeset, :billing_address_id) do
        changeset
      else
        case primary_billing_address(customer) do
          %CustomerAddress{id: id} -> put_change(changeset, :billing_address_id, id)
          nil -> add_error(changeset, :billing_address_id, "is required")
        end
      end

    Enum.reduce(
      [billing_address_id: ~w(billing either), shipping_address_id: ~w(shipping either)],
      changeset,
      fn {field, allowed}, current ->
        case get_field(current, field) do
          nil ->
            current

          id ->
            case Repo.get_by(CustomerAddress,
                   id: id,
                   customer_id: customer.id,
                   client_id: client.id
                 ) do
              %CustomerAddress{usage: usage} ->
                if usage in allowed,
                  do: current,
                  else: add_error(current, field, "cannot be used here")

              _ ->
                add_error(current, field, "must belong to this customer")
            end
        end
      end
    )
  end

  defp customer_for(client, attrs) do
    case Map.get(string_keys(attrs), "customer_id") do
      nil -> {:error, :customer_required}
      id -> Repo.fetch_by(Customer, id: id, client_id: client.id)
    end
  end

  defp original_for(client, attrs) do
    attrs = string_keys(attrs)

    case {attrs["document_type"] || "invoice", attrs["original_invoice_id"]} do
      {type, nil} when type in ["invoice", "quotation"] ->
        {:ok, nil}

      {"credit_note", id} when not is_nil(id) ->
        case Repo.fetch_by(Invoice,
               id: id,
               client_id: client.id,
               status: "issued",
               document_type: "invoice"
             ) do
          {:ok, invoice} -> {:ok, invoice}
          _ -> {:error, :original_invoice_required}
        end

      _ ->
        {:error, :invalid_document_type}
    end
  end

  defp document_type(attrs, original) do
    if original,
      do: "credit_note",
      else: Map.get(string_keys(attrs), "document_type") || "invoice"
  end

  defp matching_original(_customer, nil), do: :ok
  defp matching_original(%{id: id}, %{customer_id: id}), do: :ok
  defp matching_original(_, _), do: {:error, :credit_customer_mismatch}

  defp open_document_month(_client, %Invoice{document_type: "quotation"}), do: :ok
  defp open_document_month(client, invoice), do: open_month(client, invoice.invoice_date)

  defp open_month(client, date) do
    period = Calendar.strftime(date, "%Y-%m")

    case Repo.one(
           from m in Month,
             where:
               m.org_id == ^client.org_id and m.client_id == ^client.id and m.period == ^period,
             lock: "FOR UPDATE"
         ) do
      %Month{filed_at: filed} when not is_nil(filed) -> {:error, :month_filed}
      %Month{state: "filed"} -> {:error, :month_filed}
      _ -> :ok
    end
  end

  defp issue_original(_client, %Invoice{document_type: type}, _lines)
       when type in ["invoice", "quotation"], do: {:ok, nil}

  defp issue_original(client, invoice, lines) do
    with {:ok, original} <-
           Repo.fetch_by(Invoice,
             id: invoice.original_invoice_id,
             client_id: client.id,
             status: "issued",
             document_type: "invoice"
           ),
         true <-
           original.customer_id == invoice.customer_id and
             original.place_of_supply == invoice.place_of_supply,
         true <- Date.compare(invoice.invoice_date, original.invoice_date) != :lt do
      previous =
        Repo.all(
          from i in Invoice,
            where: i.original_invoice_id == ^original.id and i.status == "issued",
            select: i.snapshot
        )

      credited = Enum.flat_map(previous, & &1["lines"]) ++ lines

      if within_original?(credited, original.snapshot["lines"]),
        do: {:ok, original},
        else: {:error, :credit_exceeds_original}
    else
      false -> {:error, :credit_original_mismatch}
      error -> error
    end
  end

  defp within_original?(credited, original) do
    original = buckets(original)

    Enum.all?(buckets(credited), fn {key, amounts} ->
      allowed = Map.get(original, key, %{})
      Enum.all?(amounts, fn {field, value} -> value <= Map.get(allowed, field, 0) end)
    end)
  end

  defp buckets(lines) do
    Enum.reduce(lines, %{}, fn line, buckets ->
      key = {line["kind"] || "service", line["sac"], line["gst_rate"]}
      amounts = Map.take(line, ~w(taxable_paise cgst_paise sgst_paise igst_paise))
      Map.update(buckets, key, amounts, &Map.merge(&1, amounts, fn _, a, b -> a + b end))
    end)
  end

  defp financial_year(date), do: if(date.month < 4, do: date.year - 1, else: date.year)

  defp issued_in_year?(client, year, type) do
    from_date = Date.new!(year, 4, 1)
    until_date = Date.new!(year + 1, 4, 1)

    Repo.exists?(
      from i in Invoice,
        where:
          i.client_id == ^client.id and i.document_type == ^type and
            i.status != "draft" and i.invoice_date >= ^from_date and
            i.invoice_date < ^until_date
    )
  end

  defp parse_number(value) when is_integer(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_number(_), do: nil

  defp next_number(client, invoice, profile) do
    date = invoice.invoice_date
    year = financial_year(date)
    initial = initial_sequence(client, year, invoice.document_type, profile)

    %{rows: [[sequence]]} =
      Repo.query!(
        "INSERT INTO business_invoice_counters (client_id, financial_year, document_type, last_number) VALUES ($1,$2,$3,$4) ON CONFLICT (client_id, financial_year, document_type) DO UPDATE SET last_number = business_invoice_counters.last_number + 1 RETURNING last_number",
        [client.id, year, invoice.document_type, initial]
      )

    prefix =
      %{"credit_note" => "CN", "invoice" => "INV", "quotation" => "QT"}[invoice.document_type]

    if invoice.document_type == "quotation" do
      format_quotation_number(profile, year, sequence)
    else
      format_invoice_number(profile, year, sequence, prefix)
    end
  end

  defp initial_sequence(client, year, "quotation", %Profile{quotation_number_style: "custom"}) do
    case Repo.query!(
           "SELECT last_number FROM business_invoice_counters WHERE client_id = $1 AND financial_year < $2 AND document_type = 'quotation' ORDER BY financial_year DESC LIMIT 1",
           [client.id, year]
         ).rows do
      [[last]] -> last + 1
      [] -> 1
    end
  end

  defp initial_sequence(_client, _year, _type, _profile), do: 1

  defp format_invoice_number(profile, year, sequence, prefix) do
    if profile.invoice_number_style == "serial_fy" do
      "#{sequence}/#{year}-#{String.pad_leading(to_string(rem(year + 1, 100)), 2, "0")}"
    else
      "#{prefix}/#{rem(year, 100)}#{rem(year + 1, 100)}/#{String.pad_leading(to_string(sequence), 4, "0")}"
    end
  end

  defp format_quotation_number(%Profile{quotation_number_style: "serial_fy"}, year, sequence),
    do: "#{sequence}/#{year}-#{String.pad_leading(to_string(rem(year + 1, 100)), 2, "0")}"

  defp format_quotation_number(
         %Profile{quotation_number_style: "custom"} = profile,
         _year,
         sequence
       ),
       do:
         "#{profile.quotation_number_prefix}#{String.pad_leading(to_string(sequence), profile.quotation_number_min_digits, "0")}"

  defp format_quotation_number(_profile, year, sequence),
    do:
      "QT/#{rem(year, 100)}#{rem(year + 1, 100)}/#{String.pad_leading(to_string(sequence), 4, "0")}"

  defp parse_quotation_number(value, year) when is_binary(value) do
    year_suffix = "#{year}-#{String.pad_leading(to_string(rem(year + 1, 100)), 2, "0")}"
    nila_prefix = "QT/#{rem(year, 100)}#{rem(year + 1, 100)}/"

    if String.ends_with?(value, "/#{year_suffix}") and
         Regex.match?(~r/\A\d+\z/, String.replace_suffix(value, "/#{year_suffix}", "")) do
      next_number = value |> String.replace_suffix("/#{year_suffix}", "") |> parse_number()

      if next_number in 1..999_999 do
        {:ok, %{style: "serial_fy", prefix: nil, min_digits: 1, next_number: next_number}}
      else
        {:error, :invalid_quotation_numbering}
      end
    else
      parse_quotation_number_suffix(value, nila_prefix)
    end
  end

  defp parse_quotation_number(_, _), do: {:error, :invalid_quotation_numbering}

  defp parse_quotation_number_suffix(value, nila_prefix) do
    case Regex.run(~r/^(.*?)(\d+)$/u, value) do
      [_, prefix, digits] ->
        next_number = parse_number(digits)
        min_digits = String.length(digits)

        cond do
          String.length(value) > 60 or String.length(prefix) > 40 or min_digits > 8 or
            next_number not in 1..999_999 or String.trim(value) != value or
              not Regex.match?(~r/\A[[:alnum:]\/._-]*\z/u, prefix) ->
            {:error, :invalid_quotation_numbering}

          prefix == nila_prefix and min_digits == 4 ->
            {:ok, %{style: "nila", prefix: nil, min_digits: 1, next_number: next_number}}

          true ->
            {:ok,
             %{style: "custom", prefix: prefix, min_digits: min_digits, next_number: next_number}}
        end

      _ ->
        {:error, :invalid_quotation_numbering}
    end
  end

  defp validate_lines(changeset, client) do
    intra? =
      Nila.Gst.StateCodes.from_gstin(client.gstin) == get_field(changeset, :place_of_supply)

    case calculate_lines(get_field(changeset, :lines), intra?) do
      {:ok, lines} -> put_change(changeset, :totals, line_totals(lines))
      {:error, reason} -> add_error(changeset, :lines, reason)
    end
  end

  def calculate_lines(lines, intra?) when is_list(lines) and length(lines) in 1..100 do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case calculate_line(line, intra?) do
        {:ok, line} -> {:cont, {:ok, acc ++ [line]}}
        error -> {:halt, error}
      end
    end)
  end

  def calculate_lines(_, _), do: {:error, "add between 1 and 100 lines"}

  defp calculate_line(line, intra?) when is_map(line) do
    line = string_keys(line)

    description =
      if is_binary(line["description"]), do: String.trim(line["description"]), else: ""

    kind = line_kind(line)

    with true <- description != "" and String.length(description) <= 1000,
         true <- valid_code?(kind, line["sac"]),
         true <- valid_unit?(kind, line["unit"]) do
      line
      |> Map.put("description", description)
      |> Map.put("kind", kind)
      |> calculate_amounts(intra?)
    else
      _ -> {:error, "each line needs a description, valid HSN/SAC and unit"}
    end
  end

  defp calculate_line(_, _), do: {:error, "invalid line"}

  defp line_kind(line), do: line["kind"] || "service"
  defp valid_code?("service", code), do: is_binary(code) and Regex.match?(~r/^99\d{4}$/, code)

  defp valid_code?("goods", code),
    do: is_binary(code) and Regex.match?(~r/^(?!99)\d{6}(\d{2})?$/, code)

  defp valid_code?(_, _), do: false
  defp valid_unit?("goods", unit), do: unit in ~w(NOS KGS LTR MTR BOX SET)

  defp valid_unit?("service", unit),
    do: is_nil(unit) or (is_binary(unit) and String.length(unit) <= 30)

  defp valid_unit?(_, _), do: false

  defp calculate_amounts(line, intra?) when is_map(line) do
    line = string_keys(line)

    with {:ok, quantity} <- positive_decimal(line["quantity"], 4),
         {:ok, price} <- positive_decimal(line["unit_price"], 2),
         {:ok, rate} <- positive_decimal(line["gst_rate"], 3),
         true <- decimal_string(rate) in @gst_rates,
         true <-
           is_nil(line["unit"]) or (is_binary(line["unit"]) and String.length(line["unit"]) <= 30) do
      taxable =
        quantity
        |> Decimal.mult(price)
        |> Decimal.mult(100)
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()

      gst = fn divisor ->
        taxable
        |> Decimal.new()
        |> Decimal.mult(rate)
        |> Decimal.div(divisor)
        |> Decimal.round(0, :half_up)
        |> Decimal.to_integer()
      end

      {cgst, sgst, igst} = if intra?, do: {gst.(200), gst.(200), 0}, else: {0, 0, gst.(100)}

      if taxable > 0 and taxable <= 100_000_000_000 do
        {:ok,
         %{
           "description" => line["description"],
           "kind" => line_kind(line),
           "sac" => line["sac"],
           "unit" => line["unit"],
           "quantity" => decimal_string(quantity),
           "unit_price" => decimal_string(price),
           "gst_rate" => decimal_string(rate),
           "taxable_paise" => taxable,
           "cgst_paise" => cgst,
           "sgst_paise" => sgst,
           "igst_paise" => igst
         }}
      else
        {:error, "line amount must be greater than zero and within the supported limit"}
      end
    else
      _ ->
        {:error, "each line needs a positive quantity and price, and a supported GST rate"}
    end
  end

  defp calculate_amounts(_, _), do: {:error, "invalid line"}

  defp positive_decimal(value, places) when is_binary(value) do
    if byte_size(value) <= 24 and Regex.match?(~r/^\d+(\.\d+)?$/, value) do
      decimal = Decimal.new(value)

      if Decimal.compare(decimal, Decimal.new(0)) == :gt and decimal.exp >= -places,
        do: {:ok, decimal},
        else: {:error, :invalid_number}
    else
      {:error, :invalid_number}
    end
  end

  defp positive_decimal(value, places) when is_integer(value),
    do: positive_decimal(to_string(value), places)

  defp positive_decimal(_, _), do: {:error, :invalid_number}
  defp decimal_string(value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp line_totals(lines) do
    totals =
      Enum.reduce(
        lines,
        Map.new(~w(taxable_paise cgst_paise sgst_paise igst_paise), &{&1, 0}),
        fn line, totals ->
          Map.new(totals, fn {key, amount} -> {key, amount + line[key]} end)
        end
      )

    Map.put(totals, "total_paise", Enum.sum(Map.values(totals)))
  end

  defp snapshot(client, profile, customer, invoice, lines, number, original) do
    totals = line_totals(lines)

    billing =
      if invoice.billing_address_id,
        do:
          Repo.get_by!(CustomerAddress,
            id: invoice.billing_address_id,
            client_id: client.id,
            customer_id: customer.id
          ),
        else: primary_billing_address(customer)

    shipping =
      if invoice.shipping_address_id,
        do:
          Repo.get_by!(CustomerAddress,
            id: invoice.shipping_address_id,
            client_id: client.id,
            customer_id: customer.id
          ),
        else: nil

    %{
      "number" => number,
      "document_type" => invoice.document_type,
      "invoice_date" => Date.to_iso8601(invoice.invoice_date),
      "due_date" => invoice.due_date && Date.to_iso8601(invoice.due_date),
      "valid_until" => invoice.valid_until && Date.to_iso8601(invoice.valid_until),
      "subject" => invoice.subject,
      "revised_from_number" =>
        invoice.revised_from_id && Repo.get!(Invoice, invoice.revised_from_id).number,
      "notes" => invoice.notes,
      "purchase_order_number" => invoice.purchase_order_number,
      "purchase_order_date" =>
        invoice.purchase_order_date && Date.to_iso8601(invoice.purchase_order_date),
      "delivery_address" => if(shipping, do: shipping.address, else: invoice.delivery_address),
      "delivery_state_code" =>
        if(shipping, do: shipping.state_code, else: invoice.delivery_state_code),
      "shipping_name" => shipping && shipping.label,
      "shipping_gstin" => shipping && shipping.gstin,
      "total_in_words" => Nila.Formatters.amount_in_words(totals["total_paise"]),
      "supplier" => %{
        "name" => profile.legal_name,
        "address" => profile.address,
        "gstin" => client.gstin,
        "state_code" => profile.state_code,
        "phone" => profile.phone,
        "email" => profile.email,
        "logo_key" => profile.logo_key,
        "signature_key" => profile.signature_key
      },
      "customer" =>
        if(original,
          do: original.snapshot["customer"],
          else: %{
            "name" => customer.name,
            "address" => billing.address,
            "gstin" => billing.gstin,
            "state_code" => billing.state_code
          }
        ),
      "place_of_supply" => invoice.place_of_supply,
      "lines" => lines,
      "totals" => totals,
      "original_invoice_number" => original && original.number,
      "original_invoice_date" => original && Date.to_iso8601(original.invoice_date),
      "original_sale_category" => original && sale_category(original.snapshot)
    }
  end

  defp sale_category(snapshot) do
    cond do
      snapshot["customer"]["gstin"] ->
        "b2b"

      snapshot["supplier"]["state_code"] == snapshot["place_of_supply"] ->
        "b2cs"

      true ->
        threshold = if snapshot["invoice_date"] < "2024-08-01", do: 25_000_000, else: 10_000_000
        if snapshot["totals"]["total_paise"] > threshold, do: "b2cl", else: "b2cs"
    end
  end

  defp render(snapshot, opts),
    do: Keyword.get(opts, :render_pdf, &Nila.Business.Pdf.render/1).(snapshot)

  defp sales_facts(snapshot) do
    totals = snapshot["totals"]
    intra? = snapshot["supplier"]["state_code"] == snapshot["place_of_supply"]
    rupees = fn paise -> paise / 100 end

    data = %{
      "invoice_number" => snapshot["number"],
      "invoice_date" => snapshot["invoice_date"],
      "seller" => snapshot["supplier"],
      "buyer" => snapshot["customer"],
      "document_type" => snapshot["document_type"],
      "document_status" => "active",
      "recipient_registration" =>
        if(snapshot["customer"]["gstin"], do: "registered", else: "unregistered"),
      "place_of_supply" => snapshot["place_of_supply"],
      "supply_type" => "taxable",
      "tax_payment" => "not_applicable",
      "reverse_charge" => false,
      "original_sale_category" => snapshot["original_sale_category"],
      "printed_total_taxable" => rupees.(totals["taxable_paise"]),
      "printed_total_tax" =>
        rupees.(totals["cgst_paise"] + totals["sgst_paise"] + totals["igst_paise"]),
      "printed_grand_total" => rupees.(totals["total_paise"]),
      "line_items" =>
        Enum.map(snapshot["lines"], fn line ->
          rate =
            String.to_float(
              line["gst_rate"] <> if(String.contains?(line["gst_rate"], "."), do: "", else: ".0")
            )

          %{
            "description" => line["description"],
            "hsn_sac" => line["sac"],
            "quantity" => Decimal.to_float(Decimal.new(line["quantity"])),
            "uom" => if(line["kind"] == "goods", do: line["unit"], else: "OTH"),
            "printed_unit_price" => Decimal.to_float(Decimal.new(line["unit_price"])),
            "printed_taxable_value" => rupees.(line["taxable_paise"]),
            "cgst_rate" => if(intra?, do: rate / 2, else: 0),
            "sgst_rate" => if(intra?, do: rate / 2, else: 0),
            "igst_rate" => if(intra?, do: 0, else: rate),
            "cgst_amount" => rupees.(line["cgst_paise"]),
            "sgst_amount" => rupees.(line["sgst_paise"]),
            "igst_amount" => rupees.(line["igst_paise"])
          }
        end)
    }

    Nila.Gst.Extraction.Sales.Normalizer.normalize(%{"data" => data, "source_pages" => [1]})
    |> Map.put("original_invoice_number", snapshot["original_invoice_number"])
    |> Map.put("original_invoice_date", snapshot["original_invoice_date"])
  end

  def error_message(:already_issued),
    do: "This invoice has already been issued. Use a credit note to correct it."

  def error_message(:not_issued), do: "Issue the invoice before downloading its PDF."
  def error_message(:month_filed), do: "The CA has filed this month. Choose an open period."

  def error_message(:cancellation_reason_required),
    do: "Enter a cancellation reason of up to 500 characters."

  def error_message(:invoice_not_issued), do: "Only an issued invoice can be cancelled."

  def error_message(:quotation_cannot_be_cancelled),
    do: "Quotations cannot be cancelled here. Mark them declined instead."

  def error_message(:credit_note_cannot_be_cancelled),
    do: "Credit notes cannot be cancelled here."

  def error_message(:invoice_cannot_be_cancelled), do: "This invoice cannot be cancelled."

  def error_message(:issued_credit_notes_exist),
    do: "This invoice has an issued credit note and cannot be cancelled."

  def error_message(:invalid_copy_source), do: "Only invoices and quotations can be copied."
  def error_message(:sales_evidence_missing), do: "This invoice's sales evidence is missing."
  def error_message(:sales_evidence_invalid), do: "This invoice's sales evidence is invalid."

  def error_message(:primary_billing_required),
    do: "Choose another primary billing address first."

  def error_message(:primary_shipping_required),
    do: "Choose another primary shipping address first."

  def error_message(:profile_incomplete),
    do: "Complete your business details first."

  def error_message(:seller_gstin_required),
    do: "A valid business GSTIN is required. Ask your CA to update it."

  def error_message(:seller_state_mismatch),
    do: "Your business state must match its GST registration."

  def error_message(:customer_required), do: "Choose a customer."

  def error_message(:original_invoice_required),
    do: "Choose an issued invoice for this credit note."

  def error_message(:credit_exceeds_original),
    do: "This credit exceeds the original invoice's remaining amount or tax."

  def error_message(:credit_original_mismatch),
    do:
      "A credit note must keep the original customer and place of supply, and cannot precede the original invoice."

  def error_message(:credit_customer_mismatch),
    do: "A credit note must use the original invoice's customer."

  def error_message(:invalid_document_type),
    do: "Choose an invoice or a credit note linked to an issued invoice."

  def error_message(:invalid_quotation_status),
    do:
      "Finalize the quotation before changing its status. Converted quotations cannot change status."

  def error_message(:quotation_not_accepted),
    do: "Mark the quotation accepted before converting it to an invoice."

  def error_message(:not_found), do: "The record was not found."
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(_), do: "The invoice could not be saved. Please try again."

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
