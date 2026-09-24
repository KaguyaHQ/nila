defmodule NilaWeb.SalesUploadController do
  use NilaWeb, :controller

  alias Nila.Clients
  alias Nila.Gst.Sales.Uploads

  def index(conn, params), do: dispatch(conn, params, :index)
  def prepare(conn, params), do: dispatch(conn, params, :prepare)
  def move_preview(conn, params), do: dispatch(conn, params, :move_preview)
  def move(conn, params), do: dispatch(conn, params, :move)
  def removal(conn, params), do: dispatch(conn, params, :removal)
  def create(conn, params), do: dispatch(conn, params, :create)

  defp dispatch(conn, %{"client_id" => id, "period" => period} = params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         :ok <- authorize(scope, action),
         {:ok, client_id} <- client_id(id),
         :ok <- period(period),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, body} <- perform(action, scope, client.id, period, params) do
      conn |> put_resp_header("cache-control", "private, no-store") |> json(body)
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, "Verify your account and join a firm to continue.")

      {:error, :invalid} ->
        error(conn, 400, "Choose a valid client and month.")

      {:error, :read_only} ->
        error(conn, 403, "Your role can view sales bills, but cannot change uploads.")

      {:error, :not_found} ->
        error(conn, 404, "This client is not available.")

      {:error, :invalid_files} ->
        error(conn, 422, "Choose 1 to 50 PDF files, each no larger than 50 MB.")

      {:error, :invalid_token} ->
        error(conn, 422, "This upload has expired or is not available. Choose the files again.")

      {:error, :invalid_pdf} ->
        error(
          conn,
          422,
          "A file is missing, incomplete, or is not a PDF. Upload the files again."
        )

      {:error, reason}
      when reason in [
             :same_client,
             :wrong_seller,
             :stale,
             :filed,
             :mixed_sellers,
             :processing,
             :posted,
             :other_month,
             :evidence_unavailable
           ] ->
        error(conn, 409, move_error(reason))

      {:error, _} ->
        error(conn, 503, "Nila could not finish saving these files. Please try again.")
    end
  end

  defp move_error(:same_client), do: "Choose a different client."

  defp move_error(:wrong_seller),
    do: "The destination client's GSTIN must match the seller on these bills."

  defp move_error(:stale), do: "This upload changed. Close this dialog and review it again."

  defp move_error(:filed),
    do: "A source or destination month is filed. This upload cannot be changed."

  defp move_error(:mixed_sellers),
    do:
      "These bills have different or unverified sellers. The whole upload cannot be moved together."

  defp move_error(:processing),
    do: "Wait until every file in this upload has finished processing before changing it."

  defp move_error(:posted),
    do: "This upload is linked to accounting posting and cannot be changed."

  defp move_error(:other_month),
    do: "These bills are also used in another working month. This upload cannot be changed."

  defp move_error(:evidence_unavailable),
    do: "The source images could not be preserved. Nothing was moved. Try again."

  defp perform(:removal, scope, client_id, period, params),
    do:
      Nila.Gst.Sales.Invoice.Removals.change_upload(
        scope,
        client_id,
        period,
        params["batch_ref"],
        params["action"],
        params["source_ids"]
      )

  defp perform(:move_preview, scope, client_id, period, params),
    do: Nila.Gst.Sales.UploadMoves.preview(scope, client_id, period, params["batch_ref"])

  defp perform(:move, scope, client_id, period, params) do
    with {:ok, destination_id} <- destination_id(params["destination_client_id"]) do
      Nila.Gst.Sales.UploadMoves.move(
        scope,
        client_id,
        period,
        params["batch_ref"],
        destination_id,
        params["basis"]
      )
    end
  end

  defp perform(:index, scope, client_id, period, _),
    do: {:ok, Uploads.history(scope.current_org.id, client_id, period)}

  defp perform(:prepare, scope, client_id, period, %{"token" => token}),
    do: Uploads.refresh(scope, client_id, period, token)

  defp perform(:prepare, scope, client_id, period, params),
    do: Uploads.prepare(scope, client_id, period, params["files"])

  defp perform(:create, scope, client_id, period, params),
    do: Uploads.create(scope, client_id, period, params["token"])

  defp destination_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp destination_id(_), do: {:error, :invalid}

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok

  defp authorize(_scope, :index), do: :ok

  defp authorize(scope, _action) do
    if Nila.Accounts.Policy.can?(scope, :edit_records), do: :ok, else: {:error, :read_only}
  end

  defp client_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> {:ok, id}
      _ -> {:error, :invalid}
    end
  end

  defp period(value) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, value),
         {:ok, date} <- Date.from_iso8601(value <> "-01"),
         true <- date.year >= 2017 do
      :ok
    else
      _ -> {:error, :invalid}
    end
  end

  defp error(conn, status, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message})
end
