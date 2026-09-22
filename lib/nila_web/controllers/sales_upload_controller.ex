defmodule NilaWeb.SalesUploadController do
  use NilaWeb, :controller

  alias Nila.Clients
  alias Nila.Gst.Sales.Uploads

  def index(conn, params), do: dispatch(conn, params, :index)
  def prepare(conn, params), do: dispatch(conn, params, :prepare)
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
        error(conn, 403, "Your role can view sales bills, but cannot upload them.")

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

      {:error, _} ->
        error(conn, 503, "Nila could not finish saving these files. Please try again.")
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
