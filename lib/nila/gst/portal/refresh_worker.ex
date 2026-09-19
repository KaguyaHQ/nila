defmodule Nila.Gst.Portal.RefreshWorker do
  use Oban.Worker,
    queue: :workflows,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query
  alias Nila.{Repo, Gst.Portal}
  alias Nila.Gst.Portal.Connection

  @impl true
  def perform(%Oban.Job{args: %{"org_id" => org_id, "client_id" => client_id}}) do
    with {:ok, connection} <- Portal.connection(org_id, client_id),
         {:ok, _} <- Portal.account(connection) do
      :ok
    else
      {:error, reason} when reason in [:not_found, :session_expired] -> :ok
      error -> error
    end
  end

  def perform(%Oban.Job{args: %{}}) do
    now = DateTime.utc_now()

    Repo.all(
      from c in Connection,
        join: client in assoc(c, :client),
        where: c.gstin == client.gstin,
        select: {c, client.org_id}
    )
    |> Enum.each(fn {connection, org_id} ->
      if not Portal.session_expired?(connection, now) and Portal.refresh_due?(connection, now) do
        %{org_id: org_id, client_id: connection.client_id}
        |> new()
        |> Oban.insert!()
      end
    end)

    :ok
  end
end
