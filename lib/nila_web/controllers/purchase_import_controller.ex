defmodule NilaWeb.PurchaseImportController do
  use NilaWeb, :controller
  alias Nila.Accounts.Policy
  alias NilaWeb.Gst.PurchaseImportWorkspace, as: Workspace
  def read(conn, params), do: dispatch(conn, params, :read)
  def preview(conn, params), do: dispatch(conn, params, :preview)
  def create(conn, params), do: dispatch(conn, params, :create)
  def uploads(conn, params), do: dispatch(conn, params, :uploads)

  defp dispatch(conn, %{"client_id" => id, "period" => period} = params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope, action),
         {client_id, ""} when client_id > 0 and client_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(id),
         true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017,
         {:ok, client} <- Nila.Clients.get_client(scope.current_org.id, client_id),
         {:ok, result} <- perform(action, scope, client, period, params) do
      conn |> put_resp_header("cache-control", "private, no-store") |> json(result)
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "unauthenticated", "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, "forbidden", "Your role cannot import purchases.")

      {:error, :not_found} ->
        error(conn, 404, "not_found", "This client or upload is not available.")

      {:error, :signed_off} ->
        error(
          conn,
          409,
          "signed_off",
          "This month is signed off or filed. Reopen it before importing."
        )

      {:error, :invalid_file} ->
        error(
          conn,
          422,
          "invalid_file",
          "Choose an unencrypted XLSX up to 5 MB, with at most 20 sheets, 5,000 data rows per sheet and 100 columns."
        )

      {:error, :invalid_token} ->
        error(
          conn,
          422,
          "invalid_token",
          "Check the import again. This confirmation has expired or does not match the workbook."
        )

      {:error, message} when is_binary(message) ->
        error(conn, if(action == :create, do: 409, else: 422), "import_failed", message)

      {:error, :invalid_selection} ->
        error(
          conn,
          422,
          "invalid_selection",
          "Choose a valid sheet, header, column mapping and rows to leave out."
        )

      _ ->
        error(conn, 400, "invalid", "Choose a valid client, month and workbook.")
    end
  end

  defp perform(:uploads, scope, client, period, params),
    do: Workspace.history(scope, client, period, params)

  defp perform(action, scope, client, period, params) do
    with :ok <- Workspace.editable(scope, client, period),
         {:ok, file} <- Workspace.file(params["file"]) do
      case action do
        :read -> Workspace.read(file, params)
        :preview -> Workspace.preview(scope, client, period, file, params)
        :create -> Workspace.commit(scope, client, period, file, params["token"])
      end
    end
  end

  defp access(nil, _), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}, _), do: {:error, :forbidden}
  defp access(%{current_org: nil}, _), do: {:error, :forbidden}
  defp access(_, :uploads), do: :ok

  defp access(scope, _),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  defp error(conn, status, code, message),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message, code: code})
end
