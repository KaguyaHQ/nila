defmodule NilaWeb.SalesReportController do
  use NilaWeb, :controller
  alias Nila.Gst.Sales.{ReportImport, Months}

  def index(conn, params), do: dispatch(conn, params, :index)
  def create(conn, params), do: dispatch(conn, params, :create)
  def update(conn, params), do: dispatch(conn, params, :update)
  def destroy(conn, params), do: dispatch(conn, params, :destroy)

  defp dispatch(conn, %{"client_id" => id, "period" => period} = params, action) do
    scope = conn.assigns[:current_scope]

    with true <-
           not is_nil(scope) and not is_nil(scope.current_org) and
             not is_nil(scope.user.confirmed_at),
         {client_id, ""} when client_id > 0 <- Integer.parse(id),
         {:ok, _} <- Date.from_iso8601(period <> "-01"),
         {:ok, _} <- Nila.Clients.get_client(scope.current_org.id, client_id),
         {:ok, body} <- perform(action, scope, client_id, period, params) do
      conn |> put_resp_header("cache-control", "private, no-store") |> json(body)
    else
      {:error, message} when is_binary(message) ->
        error(conn, 422, message)

      {:error, :invalid_file} ->
        error(
          conn,
          422,
          "This file could not be read. Choose a supported .xls, .xlsx or .csv sales report."
        )

      {:error, :too_large} ->
        error(conn, 422, "Each sales report file must be 5 MB or less.")

      {:error, :xls_reader_unavailable} ->
        error(
          conn,
          503,
          "The legacy Excel reader is unavailable. Please try again after it is installed."
        )

      {:error, :forbidden} ->
        error(conn, 403, "Your role cannot import sales reports.")

      _ ->
        error(conn, 404, "This client or month is not available.")
    end
  end

  defp perform(:index, scope, client_id, period, _) do
    case Months.get_by_period(scope.current_org.id, client_id, period) do
      {:ok, month} ->
        {:ok,
         %{
           reports: ReportImport.review(month),
           tasks: ReportImport.tasks(month),
           states: state_options(),
           editable: is_nil(month.filed_at) and Nila.Accounts.Policy.can?(scope, :edit_records)
         }}

      _ ->
        {:ok, %{reports: [], tasks: [], states: state_options(), editable: false}}
    end
  end

  defp perform(:create, scope, client_id, period, params) do
    uploads = List.wrap(params["files"]) ++ List.wrap(params["file"])

    with :ok <-
           if(Nila.Accounts.Policy.can?(scope, :edit_records),
             do: :ok,
             else: {:error, :forbidden}
           ),
         true <- uploads != [] and Enum.all?(uploads, &match?(%Plug.Upload{}, &1)),
         {:ok, files} <- read_uploads(uploads),
         {:ok, dump} <- import_files(scope, client_id, period, files) do
      {:ok, %{ok: true, dump_id: dump.id}}
    else
      false -> {:error, "Choose a sales report."}
      error -> error
    end
  end

  defp perform(:update, scope, client_id, period, params) do
    with {:ok, month} <- Months.get_by_period(scope.current_org.id, client_id, period),
         {:ok, _} <- ReportImport.correct(scope, month, params),
         do: {:ok, %{ok: true}}
  end

  defp perform(:destroy, scope, client_id, period, %{"dump_id" => dump_id}) do
    with {:ok, _} <- ReportImport.discard(scope, client_id, period, dump_id),
         do: {:ok, %{ok: true}}
  end

  defp perform(:destroy, _, _, _, _), do: {:error, "Choose a sales report to remove."}

  defp read_uploads(uploads) when length(uploads) > 20,
    do: {:error, "Choose no more than 20 sales report files."}

  defp read_uploads(uploads) do
    Enum.reduce_while(uploads, {:ok, [], 0}, fn upload, {:ok, acc, total} ->
      case File.stat(upload.path) do
        {:ok, %{size: size}} when size in 1..5_000_000 and total + size <= 25_000_000 ->
          case File.read(upload.path) do
            {:ok, bytes} ->
              {:cont, {:ok, [%{bytes: bytes, filename: upload.filename} | acc], total + size}}

            error ->
              {:halt, error}
          end

        {:ok, %{size: size}} when size > 5_000_000 ->
          {:halt, {:error, :too_large}}

        {:ok, _} ->
          {:halt, {:error, "The sales report files must be 25 MB or less in total."}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp import_files(scope, client_id, period, [file]),
    do: ReportImport.save(scope, client_id, period, file.bytes, file.filename)

  defp import_files(scope, client_id, period, files),
    do: ReportImport.save_many(scope, client_id, period, files)

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})

  defp state_options do
    Enum.map(Nila.Gst.StateCodes.all(), fn label ->
      %{label: label, value: Nila.Gst.StateCodes.code_for(label)}
    end)
  end
end
