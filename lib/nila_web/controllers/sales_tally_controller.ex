defmodule NilaWeb.SalesTallyController do
  use NilaWeb, :controller
  alias Nila.{Clients, Accounts.Policy}
  alias Nila.Gst.Sales.Tally.Posting

  def show(conn, params), do: dispatch(conn, params, :show)
  def update(conn, params), do: dispatch(conn, params, :update)
  def post(conn, params), do: dispatch(conn, params, :post)
  def verify(conn, params), do: dispatch(conn, params, :verify)
  def sync(conn, params), do: dispatch(conn, params, :sync)

  defp dispatch(conn, params, action) do
    scope = conn.assigns[:current_scope]

    with :ok <- access(scope),
         true <- action == :show or Policy.can?(scope, :edit_records),
         true <- action != :post or Policy.can?(scope, :export),
         {client_id, ""} when client_id > 0 <- Integer.parse(params["client_id"]),
         {:ok, _} <- Date.from_iso8601(params["period"] <> "-01"),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, result} <-
           perform(action, scope.current_org.id, client, Map.put(params, :user_id, scope.user.id)),
         {:ok, data} <- Posting.load(scope.current_org.id, client, params["period"]) do
      projected = Posting.project(data)
      online = data.enabled && connector_online?(scope.current_org.id, data._company)

      projected =
        if data.enabled,
          do:
            projected
            |> Map.put(
              :can_refresh,
              data.can_refresh and online and Policy.can?(scope, :edit_records)
            )
            |> Map.update!(:sync, fn sync ->
              if online or sync.status == "running", do: sync, else: %{sync | status: "offline"}
            end)
            |> Map.put(:can_edit, data.can_edit and Policy.can?(scope, :edit_records))
            |> Map.put(
              :can_post,
              data.can_post and Policy.can?(scope, :edit_records) and Policy.can?(scope, :export)
            ),
          else: projected

      response =
        if action in [:post, :verify],
          do: %{queued_count: result, tally: projected},
          else: projected

      conn |> put_resp_header("cache-control", "private, no-store") |> json(response)
    else
      {:error, :unauthenticated} ->
        error(conn, 401, "Sign in to continue.")

      false ->
        error(conn, 403, "Your role cannot perform this action.")

      {:error, :forbidden} ->
        error(conn, 403, "Verify your account and join a firm to continue.")

      {:error, :not_found} ->
        error(conn, 404, "This client is not available.")

      {:error, :connector_offline} ->
        error(conn, 409, "Open Nila Connector and this Tally company, then refresh again.")

      {:error, :sync_in_progress} ->
        error(conn, 409, "This company is already refreshing from Tally.")

      {:error, :stale_or_not_ready} ->
        error(
          conn,
          409,
          "The proposed entries changed or are no longer ready. Refresh and review them before posting."
        )

      {:error, :tax_rate_mismatch} ->
        error(
          conn,
          422,
          "Choose a tax ledger with the bill's exact duty head and rate. A missing or different rate cannot be posted."
        )

      {:error, {:invalid_correction, field, _}} ->
        error(conn, 422, "Check the corrected value for #{field}. Nothing was saved.")

      _ ->
        error(
          conn,
          422,
          "These Tally entries could not be saved. Check the choices and try again."
        )
    end
  end

  defp perform(:show, _, _, _), do: {:ok, nil}

  defp perform(:update, org_id, client, params),
    do:
      Posting.update(
        org_id,
        client,
        params["period"],
        params["invoice_id"],
        params,
        params[:user_id]
      )

  defp perform(:post, org_id, client, params),
    do: Posting.post(org_id, client, params["period"], params)

  defp perform(:verify, org_id, client, params),
    do: Posting.verify(org_id, client, params["period"])

  defp perform(:sync, org_id, client, params) do
    with {:ok, company} <- Nila.TallyDevices.get_client_company(org_id, client.id),
         true <- company.is_open and connector_online?(org_id, company),
         {:ok, date} <- Date.from_iso8601(params["period"] <> "-01"),
         {:ok, run} <-
           Nila.TallySync.start(company.device, company.identity, Date.end_of_month(date)) do
      payload = %{
        id: run.id,
        company_identity: company.identity,
        company_name: company.name,
        period_start: Date.to_iso8601(run.period_start),
        period_end: Date.to_iso8601(run.period_end)
      }

      Phoenix.PubSub.broadcast(
        Nila.PubSub,
        Nila.TallyJobs.device_topic(company.device_id),
        {:tally_sync_requested, payload}
      )

      {:ok, run.id}
    else
      false -> {:error, :connector_offline}
      error -> error
    end
  end

  defp connector_online?(org_id, company) do
    not is_nil(company.device_id) and
      Map.has_key?(
        NilaWeb.Presence.list("tally_devices:#{org_id}"),
        Integer.to_string(company.device_id)
      )
  end

  defp access(nil), do: {:error, :unauthenticated}
  defp access(%{user: %{confirmed_at: nil}}), do: {:error, :forbidden}
  defp access(%{current_org: nil}), do: {:error, :forbidden}
  defp access(_), do: :ok

  defp error(conn, status, message),
    do:
      conn
      |> put_status(status)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{error: message})
end
