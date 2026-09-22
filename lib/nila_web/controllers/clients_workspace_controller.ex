defmodule NilaWeb.ClientsWorkspaceController do
  use NilaWeb, :controller

  alias Nila.Accounts.Policy
  alias Nila.Clients
  alias Nila.Clients.{Import, ImportXlsx}

  @import_salt "clients workspace import"

  def index(conn, params), do: dispatch(conn, params, :index)
  def show(conn, params), do: dispatch(conn, params, :show)
  def create(conn, params), do: dispatch(conn, params, :create)
  def update(conn, params), do: dispatch(conn, params, :update)
  def preview_import(conn, params), do: dispatch(conn, params, :preview_import)
  def import_clients(conn, params), do: dispatch(conn, params, :import_clients)

  defp dispatch(conn, params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         :ok <- authorize(scope, action),
         {:ok, result} <- perform(action, scope, params) do
      conn |> put_resp_header("cache-control", "private, no-store") |> json(result)
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "Sign in to continue.")

      {:error, :forbidden} ->
        error(conn, 403, "Your account cannot change clients.")

      {:error, :not_found} ->
        error(conn, 404, "This client is not available.")

      {:error, :invalid} ->
        error(conn, 400, "Choose a valid client and month.")

      {:error, :invalid_attrs} ->
        error(conn, 422, "Enter a client name and an optional GSTIN.")

      {:error, :name_too_long} ->
        error(conn, 422, "Check the client details.", %{
          name: ["should be at most 255 character(s)"]
        })

      {:error, :invalid_token} ->
        error(
          conn,
          422,
          "This import preview has expired or is not available. Preview the workbook again."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
            Enum.reduce(opts, message, fn {key, value}, result ->
              String.replace(result, "%{#{key}}", to_string(value))
            end)
          end)

        error(conn, 422, "Check the client details.", errors)

      {:error, reason} ->
        error(conn, 422, Import.error_message(reason))
    end
  end

  defp perform(:index, scope, params) do
    with {:ok, period} <- selected_period(params["period"]) do
      clients =
        Enum.map(Clients.list_clients(scope.current_org.id), fn client ->
          client_json(client)
          |> Map.put(:sales_path, "/gst/#{client.id}/#{period}/sales")
        end)

      {:ok,
       %{
         clients: clients,
         user: %{name: scope.user.name, org: scope.current_org.name},
         can_edit: Policy.can?(scope, :edit_records),
         period: period
       }}
    end
  end

  defp perform(:show, scope, params) do
    with {:ok, client} <- fetch_client(scope, params["id"]) do
      {:ok, client_response(scope, client)}
    end
  end

  defp perform(:create, scope, params) do
    with {:ok, attrs} <- client_attrs(params["client"]),
         attrs =
           Map.merge(attrs, %{
             "org_id" => scope.current_org.id,
             "type" => "company",
             "chase_channel" => "none"
           }),
         {:ok, client} <- Clients.create_client(attrs) do
      {:ok, client_response(scope, client)}
    end
  end

  defp perform(:update, scope, params) do
    with {:ok, client} <- fetch_client(scope, params["id"]),
         {:ok, attrs} <- client_attrs(params["client"]),
         {:ok, client} <- Clients.update_client(client, attrs) do
      {:ok, client_response(scope, client)}
    end
  end

  defp perform(:preview_import, scope, params) do
    with {:ok, bytes} <- read_workbook(params["file"]),
         {:ok, preview} <- Import.preview(scope, bytes) do
      payload = %{org_id: scope.current_org.id, user_id: scope.user.id, rows: preview.rows}

      {:ok,
       %{
         rows: json_rows(preview.rows),
         token: Phoenix.Token.sign(NilaWeb.Endpoint, @import_salt, payload),
         ready_count: Enum.count(preview.rows, &(&1.status == :ready))
       }}
    end
  end

  defp perform(:import_clients, scope, params) do
    with {:ok, rows} <- import_rows(scope, params["token"]),
         {:ok, results} <- Import.save(scope, rows) do
      {:ok,
       %{
         rows: json_rows(results),
         added_count: Enum.count(results, &(&1.status == :added)),
         skipped_count: Enum.count(results, &(&1.status == :skip)),
         invalid_count: Enum.count(results, &(&1.status == :invalid))
       }}
    end
  end

  defp import_rows(scope, token) when is_binary(token) do
    with {:ok, payload} <-
           Phoenix.Token.verify(NilaWeb.Endpoint, @import_salt, token, max_age: 3600),
         true <- payload.org_id == scope.current_org.id and payload.user_id == scope.user.id do
      {:ok, payload.rows}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp import_rows(_, _), do: {:error, :invalid_token}

  defp read_workbook(%Plug.Upload{path: path, filename: filename}) do
    with true <- String.downcase(Path.extname(filename)) == ".xlsx",
         {:ok, stat} <- File.stat(path),
         true <- stat.size <= ImportXlsx.max_bytes() or {:error, :too_large},
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :invalid_file}
    end
  end

  defp read_workbook(_), do: {:error, :invalid_file}

  defp json_rows(rows),
    do: Enum.map(rows, &Map.take(&1, [:row, :name, :gstin, :gst_username, :status, :message]))

  defp client_response(scope, client),
    do: %{client: client_json(client), can_edit: Policy.can?(scope, :edit_records)}

  defp client_json(client), do: Map.take(client, [:id, :name, :gstin])

  defp client_attrs(attrs) when is_map(attrs) do
    if is_binary(attrs["name"]) and String.length(attrs["name"]) > 255,
      do: {:error, :name_too_long},
      else: {:ok, Map.take(attrs, ["name", "gstin"])}
  end

  defp client_attrs(_), do: {:error, :invalid_attrs}

  defp fetch_client(scope, id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 ->
        Clients.get_client(scope.current_org.id, id)

      _ ->
        {:error, :invalid}
    end
  end

  defp fetch_client(_, _), do: {:error, :invalid}

  defp selected_period(nil) do
    {:ok,
     Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1) |> Calendar.strftime("%Y-%m")}
  end

  defp selected_period(period) when is_binary(period) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}\z/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01"),
         true <- date.year >= 2017 do
      {:ok, period}
    else
      _ -> {:error, :invalid}
    end
  end

  defp selected_period(_), do: {:error, :invalid}
  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok

  defp authorize(_scope, action) when action in [:index, :show], do: :ok

  defp authorize(scope, _),
    do: if(Policy.can?(scope, :edit_records), do: :ok, else: {:error, :forbidden})

  defp error(conn, status, message, errors \\ %{}),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(status)
      |> json(%{error: message, errors: errors})
end
