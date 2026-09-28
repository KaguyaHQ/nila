defmodule NilaWeb.BusinessController do
  use NilaWeb, :controller

  alias Nila.Business.Access
  alias Nila.Business.Invoicing

  def bootstrap(conn, params), do: dispatch(conn, params, :bootstrap)
  def profile(conn, params), do: dispatch(conn, params, :profile)
  def upload_asset(conn, params), do: dispatch(conn, params, :upload_asset)
  def asset(conn, params), do: dispatch(conn, params, :asset)
  def remove_asset(conn, params), do: dispatch(conn, params, :remove_asset)
  def quotation_numbering(conn, params), do: dispatch(conn, params, :quotation_numbering)
  def invoice_numbering(conn, params), do: dispatch(conn, params, :invoice_numbering)
  def services(conn, params), do: dispatch(conn, params, :services)
  def create_service(conn, params), do: dispatch(conn, params, :create_service)
  def update_service(conn, params), do: dispatch(conn, params, :update_service)
  def delete_service(conn, params), do: dispatch(conn, params, :delete_service)
  def create_customer(conn, params), do: dispatch(conn, params, :create_customer)
  def update_customer(conn, params), do: dispatch(conn, params, :update_customer)
  def create_customer_address(conn, params), do: dispatch(conn, params, :create_customer_address)
  def update_customer_address(conn, params), do: dispatch(conn, params, :update_customer_address)
  def create_invoice(conn, params), do: dispatch(conn, params, :create_invoice)
  def finalize_quotation(conn, params), do: dispatch(conn, params, :finalize_quotation)
  def finalize_invoice(conn, params), do: dispatch(conn, params, :finalize_invoice)
  def update_invoice(conn, params), do: dispatch(conn, params, :update_invoice)
  def delete_invoice(conn, params), do: dispatch(conn, params, :delete_invoice)
  def show_invoice(conn, params), do: dispatch(conn, params, :show_invoice)
  def issue_invoice(conn, params), do: dispatch(conn, params, :issue_invoice)
  def cancel_invoice(conn, params), do: dispatch(conn, params, :cancel_invoice)
  def copy_invoice(conn, params), do: dispatch(conn, params, :copy_invoice)
  def quotation_status(conn, params), do: dispatch(conn, params, :quotation_status)
  def convert_quotation(conn, params), do: dispatch(conn, params, :convert_quotation)
  def revise_quotation(conn, params), do: dispatch(conn, params, :revise_quotation)
  def pdf(conn, params), do: dispatch(conn, params, :pdf)
  def preview(conn, params), do: dispatch(conn, params, :preview)
  def calculate(conn, params), do: dispatch(conn, params, :calculate)

  defp dispatch(conn, params, action) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, client, user} <- access(conn.assigns[:current_scope], params),
         :ok <- valid_ids(params),
         {:ok, result} <- perform(action, client, user, params) do
      case result do
        {:pdf, bytes, filename} ->
          conn
          |> put_resp_content_type("application/pdf")
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{filename}")
          )
          |> send_resp(200, bytes)

        {:asset, bytes, content_type} ->
          conn
          |> put_resp_content_type(content_type)
          |> send_resp(200, bytes)

        data ->
          json(conn, data)
      end
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp access(nil, _params), do: {:error, :unauthenticated}

  defp access(%{user: %{active: true, confirmed_at: confirmed} = user}, %{
         "business_id" => business_id
       })
       when not is_nil(confirmed) do
    case Access.client_for_user(user.id, business_id) do
      %Nila.Clients.Client{} = client -> {:ok, client, user}
      nil -> {:error, :forbidden}
    end
  end

  defp access(_, _), do: {:error, :forbidden}

  defp perform(:bootstrap, client, _user, _params) do
    {:ok,
     %{
       business: Map.take(client, [:id, :name, :gstin, :address]),
       profile: profile_json(Invoicing.get_profile(client)),
       quotation_numbering: Invoicing.quotation_numbering(client),
       invoice_numbering: Invoicing.invoice_numbering(client),
       services: Enum.map(Invoicing.list_services(client), &service_json/1),
       customers: Enum.map(Invoicing.list_customers(client), &customer_json/1),
       customer_addresses:
         Enum.map(Invoicing.list_customer_addresses(client), &customer_address_json/1),
       invoices: Enum.map(Invoicing.list_invoices(client), &invoice_json/1),
       states:
         Enum.map(Nila.Gst.StateCodes.all(), fn name ->
           %{name: name, code: Nila.Gst.StateCodes.code_for(name)}
         end)
     }}
  end

  defp perform(:services, client, _user, _params),
    do: {:ok, %{services: Enum.map(Invoicing.list_services(client), &service_json/1)}}

  defp perform(:create_service, client, _user, %{"service" => attrs}) when is_map(attrs) do
    with {:ok, service} <- Invoicing.create_service(client, attrs),
         do: {:ok, %{service: service_json(service)}}
  end

  defp perform(:update_service, client, _user, %{"id" => id, "service" => attrs})
       when is_map(attrs) do
    with {:ok, service} <- Invoicing.update_service(client, id, attrs),
         do: {:ok, %{service: service_json(service)}}
  end

  defp perform(:delete_service, client, _user, %{"id" => id}) do
    with {:ok, _service} <- Invoicing.delete_service(client, id), do: {:ok, %{deleted: true}}
  end

  defp perform(:profile, client, _user, %{"profile" => attrs}) when is_map(attrs) do
    with {:ok, profile} <- Invoicing.save_profile(client, attrs),
         do: {:ok, %{profile: profile_json(profile)}}
  end

  defp perform(:quotation_numbering, client, _user, %{"numbering" => attrs})
       when is_map(attrs) do
    with {:ok, numbering} <- Invoicing.configure_quotation_numbering(client, attrs),
         do: {:ok, %{quotation_numbering: numbering}}
  end

  defp perform(:invoice_numbering, client, _user, %{"numbering" => attrs})
       when is_map(attrs) do
    with {:ok, numbering} <- Invoicing.configure_invoice_numbering(client, attrs),
         do: {:ok, %{invoice_numbering: numbering}}
  end

  defp perform(:upload_asset, client, _user, %{"kind" => kind, "image" => %Plug.Upload{} = upload}) do
    with {:ok, %{size: size}} when size <= 512_000 <- File.stat(upload.path),
         {:ok, bytes} <- File.read(upload.path),
         {:ok, profile} <- Invoicing.save_brand_asset(client, kind, bytes) do
      {:ok, %{profile: profile_json(profile)}}
    else
      _ -> {:error, :invalid_asset}
    end
  end

  defp perform(:asset, client, _user, %{"kind" => kind}) do
    with {:ok, bytes, content_type} <- Invoicing.get_brand_asset(client, kind),
         do: {:ok, {:asset, bytes, content_type}}
  end

  defp perform(:remove_asset, client, _user, %{"kind" => kind}) do
    with {:ok, profile} <- Invoicing.remove_brand_asset(client, kind),
         do: {:ok, %{profile: profile_json(profile)}}
  end

  defp perform(:create_customer, client, _user, %{"customer" => attrs}) when is_map(attrs) do
    with {:ok, customer} <- Invoicing.create_customer(client, attrs),
         do: {:ok, %{customer: customer_json(customer)}}
  end

  defp perform(:update_customer, client, _user, %{"id" => id, "customer" => attrs})
       when is_map(attrs) do
    with {:ok, customer} <- Invoicing.update_customer(client, id, attrs),
         do: {:ok, %{customer: customer_json(customer)}}
  end

  defp perform(:create_customer_address, client, _user, %{
         "customer_id" => customer_id,
         "address" => attrs
       })
       when is_map(attrs) do
    with {:ok, address} <- Invoicing.create_customer_address(client, customer_id, attrs),
         do: {:ok, %{address: customer_address_json(address)}}
  end

  defp perform(:update_customer_address, client, _user, %{
         "customer_id" => customer_id,
         "id" => id,
         "address" => attrs
       })
       when is_map(attrs) do
    with {:ok, address} <- Invoicing.update_customer_address(client, customer_id, id, attrs),
         do: {:ok, %{address: customer_address_json(address)}}
  end

  defp perform(:create_invoice, client, user, %{"invoice" => attrs}) when is_map(attrs) do
    with {:ok, invoice} <- Invoicing.save_draft(client, user.id, attrs),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:finalize_quotation, client, user, %{"invoice" => attrs} = params)
       when is_map(attrs) do
    with {:ok, invoice} <-
           Invoicing.finalize_quotation(client, user.id, attrs, params["id"]),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:finalize_invoice, client, user, %{"invoice" => attrs} = params)
       when is_map(attrs) do
    with {:ok, invoice} <- Invoicing.finalize_invoice(client, user.id, attrs, params["id"]),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:update_invoice, client, user, %{"id" => id, "invoice" => attrs})
       when is_map(attrs) do
    with {:ok, invoice} <- Invoicing.update_draft(client, id, user.id, attrs),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:delete_invoice, client, _user, %{"id" => id}) do
    with {:ok, _invoice} <- Invoicing.delete_draft(client, id), do: {:ok, %{deleted: true}}
  end

  defp perform(:show_invoice, client, _user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.get_invoice(client, id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:issue_invoice, client, user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.issue(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:cancel_invoice, client, user, %{"id" => id, "cancellation" => attrs})
       when is_map(attrs) do
    with {:ok, invoice} <-
           Invoicing.cancel_invoice(client, id, user.id, attrs["reason"]),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:copy_invoice, client, user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.copy_to_draft(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:quotation_status, client, user, %{"id" => id, "status" => _} = params) do
    attrs =
      Map.take(params, [
        "status",
        "sent_on",
        "purchase_order_number",
        "purchase_order_date"
      ])

    with {:ok, invoice} <- Invoicing.quotation_status(client, id, user.id, attrs),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:convert_quotation, client, user, %{"id" => id}) do
    with {:ok, %{invoice: invoice, quotation: quotation}} <-
           Invoicing.convert_quotation(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice), quotation: invoice_json(quotation)}}
  end

  defp perform(:revise_quotation, client, user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.revise_quotation(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:preview, client, _user, %{"invoice" => attrs}) when is_map(attrs) do
    with {:ok, bytes} <- Invoicing.preview(client, attrs), do: {:ok, {:pdf, bytes, "preview.pdf"}}
  end

  defp perform(:calculate, client, _user, %{"invoice" => attrs}) when is_map(attrs),
    do: Invoicing.calculate(client, attrs)

  defp perform(:pdf, client, _user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.get_invoice(client, id),
         {:ok, bytes} <- Invoicing.download(client, id),
         do: {:ok, {:pdf, bytes, "#{invoice.document_type}-#{id}.pdf"}}
  end

  defp perform(_, _, _, _), do: {:error, :invalid_attrs}

  defp valid_ids(params) do
    attrs = if is_map(params["invoice"]), do: params["invoice"], else: %{}

    ids = [
      params["id"],
      params["customer_id"],
      attrs["customer_id"],
      attrs["original_invoice_id"],
      attrs["billing_address_id"],
      attrs["shipping_address_id"]
    ]

    if Enum.all?(ids, &valid_id?/1), do: :ok, else: {:error, :not_found}
  end

  defp valid_id?(nil), do: true
  defp valid_id?(id) when is_integer(id), do: id > 0 and id <= 9_223_372_036_854_775_807

  defp valid_id?(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} -> valid_id?(number)
      _ -> false
    end
  end

  defp valid_id?(_), do: false

  defp profile_json(profile),
    do:
      Map.take(profile, [
        :legal_name,
        :address,
        :state_code,
        :phone,
        :email,
        :quotation_number_style,
        :invoice_number_style,
        :e_invoice_not_applicable,
        :domestic_services_only,
        :domestic_goods_and_services_only
      ])
      |> Map.put(:has_logo, not is_nil(profile.logo_key))
      |> Map.put(:has_signature, not is_nil(profile.signature_key))

  defp service_json(service),
    do:
      service
      |> Map.take([:id, :description, :sac, :kind, :unit])
      |> Map.put(:unit_price, Decimal.to_string(Decimal.normalize(service.unit_price), :normal))
      |> Map.put(:gst_rate, Decimal.to_string(Decimal.normalize(service.gst_rate), :normal))

  defp customer_json(customer),
    do: Map.take(customer, [:id, :name, :address, :gstin, :state_code])

  defp customer_address_json(address),
    do:
      Map.take(address, [
        :id,
        :customer_id,
        :label,
        :address,
        :state_code,
        :gstin,
        :usage,
        :is_primary_billing,
        :is_primary_shipping
      ])

  defp invoice_json(invoice) do
    Map.take(invoice, [
      :id,
      :number,
      :document_type,
      :original_invoice_id,
      :status,
      :customer_id,
      :billing_address_id,
      :shipping_address_id,
      :invoice_date,
      :due_date,
      :valid_until,
      :converted_invoice_id,
      :revised_from_id,
      :place_of_supply,
      :lines,
      :notes,
      :purchase_order_number,
      :purchase_order_date,
      :delivery_address,
      :delivery_state_code,
      :subject,
      :totals,
      :snapshot,
      :issued_at,
      :sent_on,
      :cancelled_at,
      :cancelled_by_id,
      :cancellation_reason,
      :inserted_at
    ])
  end

  defp failure(conn, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn |> put_status(422) |> json(%{error: "Check the highlighted details.", errors: errors})
  end

  defp failure(conn, reason) do
    {status, message} =
      case reason do
        :unauthenticated ->
          {401, "Sign in to continue."}

        :forbidden ->
          {403, "This account does not have business access."}

        :not_found ->
          {404, "This record is not available."}

        :issued ->
          {409, "This invoice is already issued. Create a credit note to correct it."}

        :already_issued ->
          {409, "This invoice is already issued. Reload to view it."}

        :draft_in_use ->
          {409, "This draft is linked to another document and cannot be deleted."}

        :issued_credit_notes_exist ->
          {409, "This invoice has an issued credit note and cannot be cancelled."}

        reason when reason in [:filed, :month_filed] ->
          {409,
           "Your CA has already filed this month, so documents in it cannot be issued or cancelled."}

        :profile_incomplete ->
          {422, "Complete your business details first."}

        :numbering_started ->
          {409,
           "Quotation numbers are locked after the first finalized quote this financial year."}

        :invalid_numbering ->
          {422, "Choose a number format and a next number between 1 and 999999."}

        :invalid_quotation_numbering ->
          {422, "Enter a quotation number ending in digits, such as GR-50."}

        :number_already_used ->
          {409, "That document number has already been used. Choose the next unused number."}

        :invalid_asset ->
          {422, "Choose a PNG or JPEG image smaller than 500 KB."}

        reason when reason in [:typst_not_found, :pdf_renderer_unavailable] ->
          {503, "PDF generation is unavailable. Your invoice has not been issued."}

        reason when reason in [:pdf_render_timeout, :pdf_render_failed, :invalid_pdf_output] ->
          {503, "The PDF could not be created. Your invoice is still a draft; please try again."}

        :invalid_attrs ->
          {422, "Enter valid invoice details."}

        _ ->
          {422, Invoicing.error_message(reason)}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
