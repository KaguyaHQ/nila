defmodule Nila.Gst.Portal.Gstr2b do
  @moduledoc "Fetch and retain GSTR-2B documents, without importing or reconciling purchases."
  import Ecto.Query
  alias Nila.{Clients, Repo}
  alias Nila.Accounts.Policy
  alias Nila.Gst.Portal
  alias Nila.Gst.Portal.{Statement, StatementWorker}

  def subscribe(org_id), do: Phoenix.PubSub.subscribe(Nila.PubSub, "gst_statements:#{org_id}")

  def notify(org_id, id),
    do:
      Phoenix.PubSub.broadcast(
        Nila.PubSub,
        "gst_statements:#{org_id}",
        {:gst_statement_fetched, id}
      )

  def fetching?(%Statement{id: id}) do
    Repo.exists?(
      from j in Oban.Job,
        where:
          j.worker == "Nila.Gst.Portal.StatementWorker" and
            fragment("? @> ?", j.args, ^%{"statement_id" => id}) and
            j.state in ["available", "scheduled", "executing", "retryable", "suspended"]
    )
  end

  def fetching?(_), do: false

  def saved(org_id, client_id, period) do
    Repo.one(
      from s in Statement,
        join: c in assoc(s, :client),
        where:
          c.org_id == ^org_id and c.id == ^client_id and c.gstin == s.gstin and
            s.period == ^period
    )
  end

  def enqueue(scope, client_id, period) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, _date} <- month(period),
         {:ok, client} <- Clients.get_client(scope.current_org.id, client_id),
         {:ok, connection} <- Portal.connection(scope.current_org.id, client.id),
         {:ok, _} <- Portal.account(connection) do
      Repo.transact(fn ->
        Repo.insert!(%Statement{client_id: client.id, gstin: connection.gstin, period: period},
          on_conflict: :nothing,
          conflict_target: [:client_id, :gstin, :period]
        )

        statement =
          Repo.one!(
            from s in Statement,
              where:
                s.client_id == ^client.id and s.gstin == ^connection.gstin and s.period == ^period,
              lock: "FOR UPDATE"
          )

        job =
          %{org_id: scope.current_org.id, statement_id: statement.id}
          |> StatementWorker.new()
          |> Oban.insert!()

        if not job.conflict? do
          statement |> Ecto.Changeset.change(status: "pending", last_error: nil) |> Repo.update!()
        end

        {:ok, job}
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def fetch(org_id, id) do
    Repo.fetch_one(
      from s in Statement,
        join: c in assoc(s, :client),
        where: c.org_id == ^org_id and s.id == ^id
    )
  end

  def download(scope, id) do
    with true <- Policy.can?(scope, :export),
         {:ok, statement} <- fetch(scope.current_org.id, id),
         true <- is_map(statement.document) do
      {:ok, statement, Jason.encode!(statement.document)}
    else
      _ -> {:error, :not_found}
    end
  end

  def sync(org_id, id) do
    with {:ok, statement} <- fetch(org_id, id) do
      result =
        with {:ok, connection} <- Portal.connection(org_id, statement.client_id),
             true <- connection.gstin == statement.gstin,
             {:ok, date} <- month(statement.period),
             {:ok, response} <- Portal.gstr2b(org_id, statement.client_id, statement.gstin, date),
             {:ok, document} <-
               document(response, statement.gstin, Calendar.strftime(date, "%m%Y")) do
          {:ok, document}
        else
          false -> {:error, :invalid_connection}
          error -> error
        end

      case result do
        {:ok, document} ->
          statement
          |> Ecto.Changeset.change(
            document: document,
            fetched_at: DateTime.utc_now(),
            status: "ready",
            last_error: nil
          )
          |> Repo.update()

        {:error, reason} ->
          statement
          |> Ecto.Changeset.change(status: "failed", last_error: error_message(reason))
          |> Repo.update!()

          {:error, reason}
      end
    end
  end

  def record_failure(org_id, id, reason) do
    with {:ok, statement} <- fetch(org_id, id) do
      statement
      |> Ecto.Changeset.change(status: "failed", last_error: error_message(reason))
      |> Repo.update()
    end
  end

  # Verified live: Whitebooks wraps the portal's {chksum, data} JSON in its
  # status envelope. Save the portal document, never authentication metadata.
  def document(
        %{
          "data" =>
            %{"data" => %{"gstin" => gstin, "rtnprd" => period, "docdata" => docdata}} = document
        },
        gstin,
        period
      )
      when is_map(docdata) do
    {:ok, Map.take(document, ~w(chksum data))}
  end

  def document(_, _, _), do: {:error, :unexpected_response}

  def month(period) when is_binary(period) do
    with true <- Regex.match?(~r/^\d{4}-\d{2}$/, period),
         {:ok, date} <- Date.from_iso8601(period <> "-01") do
      {:ok, date}
    else
      _ -> {:error, :invalid_period}
    end
  end

  def month(_), do: {:error, :invalid_period}

  def error_message(:invalid_period), do: "Choose a valid return month."

  def error_message(:unexpected_response),
    do:
      "WhiteBooks did not return a complete GSTR-2B statement for this GSTIN and month. Any earlier download is still available."

  def error_message({:provider, _code}),
    do:
      "Could not fetch this statement. Check that GSTR-2B is available for this month and try again."

  def error_message(:session_expired),
    do: "The GST session has expired. Reconnect this client's GST account and try again."

  def error_message(:not_found), do: "Connect this client's GST account first."

  def error_message(:invalid_connection),
    do: "The client's GSTIN has changed. Reconnect GST and try again."

  def error_message(:forbidden), do: "Your role cannot fetch statements."

  def error_message(:not_configured),
    do: "WhiteBooks is not configured. Ask your administrator to set up the connection."

  def error_message(_),
    do: "The statement could not be fetched. Try again. Any earlier download is still available."
end
