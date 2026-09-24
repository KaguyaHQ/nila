defmodule NilaWeb.BusinessController do
  use NilaWeb, :controller

  alias Nila.Business.Invoicing

  def bootstrap(conn, params), do: dispatch(conn, params, :bootstrap)
  def profile(conn, params), do: dispatch(conn, params, :profile)
  def services(conn, params), do: dispatch(conn, params, :services)
  def create_service(conn, params), do: dispatch(conn, params, :create_service)
  def update_service(conn, params), do: dispatch(conn, params, :update_service)
  def delete_service(conn, params), do: dispatch(conn, params, :delete_service)
  def create_customer(conn, params), do: dispatch(conn, params, :create_customer)
  def update_customer(conn, params), do: dispatch(conn, params, :update_customer)
  def create_invoice(conn, params), do: dispatch(conn, params, :create_invoice)
  def update_invoice(conn, params), do: dispatch(conn, params, :update_invoice)
  def show_invoice(conn, params), do: dispatch(conn, params, :show_invoice)
  def issue_invoice(conn, params), do: dispatch(conn, params, :issue_invoice)
  def quotation_status(conn, params), do: dispatch(conn, params, :quotation_status)
  def convert_quotation(conn, params), do: dispatch(conn, params, :convert_quotation)
  def pdf(conn, params), do: dispatch(conn, params, :pdf)
  def preview(conn, params), do: dispatch(conn, params, :preview)
  def calculate(conn, params), do: dispatch(conn, params, :calculate)

  defp dispatch(conn, params, action) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    with {:ok, client, user} <- access(conn.assigns[:current_scope]),
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

        data ->
          json(conn, data)
      end
    else
      {:error, reason} -> failure(conn, reason)
    end
  end

  defp access(nil), do: {:error, :unauthenticated}

  defp access(%{
         user: %{active: true, confirmed_at: confirmed} = user,
         business_client: %Nila.Clients.Client{} = client,
         current_org: nil
       })
       when not is_nil(confirmed), do: {:ok, client, user}

  defp access(_), do: {:error, :forbidden}

  defp perform(:bootstrap, client, _user, _params) do
    {:ok,
     %{
       business: Map.take(client, [:id, :name, :gstin, :address]),
       profile: profile_json(Invoicing.get_profile(client)),
       services: Enum.map(Invoicing.list_services(client), &service_json/1),
       customers: Enum.map(Invoicing.list_customers(client), &customer_json/1),
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

  defp perform(:create_customer, client, _user, %{"customer" => attrs}) when is_map(attrs) do
    with {:ok, customer} <- Invoicing.create_customer(client, attrs),
         do: {:ok, %{customer: customer_json(customer)}}
  end

  defp perform(:update_customer, client, _user, %{"id" => id, "customer" => attrs})
       when is_map(attrs) do
    with {:ok, customer} <- Invoicing.update_customer(client, id, attrs),
         do: {:ok, %{customer: customer_json(customer)}}
  end

  defp perform(:create_invoice, client, user, %{"invoice" => attrs}) when is_map(attrs) do
    with {:ok, invoice} <- Invoicing.save_draft(client, user.id, attrs),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:update_invoice, client, user, %{"id" => id, "invoice" => attrs})
       when is_map(attrs) do
    with {:ok, invoice} <- Invoicing.update_draft(client, id, user.id, attrs),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:show_invoice, client, _user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.get_invoice(client, id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:issue_invoice, client, user, %{"id" => id}) do
    with {:ok, invoice} <- Invoicing.issue(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:quotation_status, client, user, %{"id" => id, "status" => status}) do
    with {:ok, invoice} <- Invoicing.quotation_status(client, id, user.id, status),
         do: {:ok, %{invoice: invoice_json(invoice)}}
  end

  defp perform(:convert_quotation, client, user, %{"id" => id}) do
    with {:ok, %{invoice: invoice, quotation: quotation}} <-
           Invoicing.convert_quotation(client, id, user.id),
         do: {:ok, %{invoice: invoice_json(invoice), quotation: invoice_json(quotation)}}
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
    ids = [params["id"], attrs["customer_id"], attrs["original_invoice_id"]]
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
        :e_invoice_not_applicable,
        :domestic_services_only,
        :domestic_goods_and_services_only
      ])

  defp service_json(service),
    do:
      service
      |> Map.take([:id, :description, :sac, :kind, :unit])
      |> Map.put(:unit_price, Decimal.to_string(Decimal.normalize(service.unit_price), :normal))
      |> Map.put(:gst_rate, Decimal.to_string(Decimal.normalize(service.gst_rate), :normal))

  defp customer_json(customer),
    do: Map.take(customer, [:id, :name, :address, :gstin, :state_code])

  defp invoice_json(invoice) do
    Map.take(invoice, [
      :id,
      :number,
      :document_type,
      :original_invoice_id,
      :status,
      :customer_id,
      :invoice_date,
      :due_date,
      :valid_until,
      :converted_invoice_id,
      :place_of_supply,
      :lines,
      :notes,
      :purchase_order_number,
      :purchase_order_date,
      :delivery_address,
      :totals,
      :snapshot,
      :issued_at,
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

        reason when reason in [:filed, :month_filed] ->
          {409,
           "Your CA has already filed this month. Contact them before issuing this document."}

        :profile_incomplete ->
          {422, "Complete your business details and confirm the invoicing requirements first."}

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
