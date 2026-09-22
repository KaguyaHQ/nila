defmodule NilaWeb.SalesReviewController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias NilaWeb.Gst.SalesReviewWorkspace, as: Workspace

  def show(conn, params), do: dispatch(conn, params, :show)
  def update(conn, params), do: dispatch(conn, params, :update)
  def confirm(conn, params), do: dispatch(conn, params, :confirm)

  defp dispatch(
         conn,
         %{"client_id" => id, "period" => period, "invoice_id" => source_id} = params,
         action
       ) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         :ok <- authorize(scope, action),
         {:ok, client_id} <- parse_id(id),
         :ok <- validate_period(period),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, context} <- Workspace.load(scope, client, period, source_id),
         :ok <- perform(action, context, params),
         {:ok, context} <- refresh(action, context, scope, client, period, source_id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> json(Workspace.project(context))
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, "Your role cannot change this invoice.")

      {:error, :invalid} ->
        error(conn, 400, "Choose a valid client and month.")

      {:error, reason} when reason in [:not_found, :source_not_found, :ambiguous_source] ->
        error(conn, 404, "This invoice is not available.")

      {:error, :filed} ->
        error(conn, 409, "This month is filed. Its recorded invoices cannot be changed.")

      {:error, :no_source} ->
        error(conn, 409, "The original source is not available for editing.")

      {:error, :unsupported_confirmation} ->
        error(
          conn,
          422,
          "This check cannot be confirmed. Refresh the invoice and review its remaining issues."
        )

      {:error, {:invalid_correction, field, reason}} ->
        error(conn, 422, "Check the edited values.", %{field => [correction_message(reason)]})

      {:error, _} ->
        error(conn, 422, "These changes could not be saved. Check the values and try again.")
    end
  end

  defp perform(:show, _, _), do: :ok
  defp perform(:update, context, params), do: Workspace.update(context, params)
  defp perform(:confirm, context, params), do: Workspace.confirm(context, params["target"])
  defp refresh(:show, context, _, _, _, _), do: {:ok, context}

  defp refresh(_, _, scope, client, period, source_id),
    do: Workspace.load(scope, client, period, source_id)

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok
  defp authorize(_, :show), do: :ok

  defp authorize(scope, _),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp validate_period(period) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017 do
      :ok
    else
      _ -> {:error, :invalid}
    end
  end

  defp correction_message(:invalid_number), do: "Enter an amount of zero or more."
  defp correction_message(:invalid_date), do: "Enter a valid invoice date."
  defp correction_message(:invalid_gstin), do: "Enter a valid GSTIN or leave it blank."
  defp correction_message(:invalid_place_of_supply), do: "Choose a valid place of supply."
  defp correction_message(:line_not_found), do: "This invoice line is no longer available."
  defp correction_message(_), do: "This value cannot be saved."

  defp error(conn, status, message, errors \\ %{}),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message, errors: errors})
end
