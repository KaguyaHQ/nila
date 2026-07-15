defmodule Nila.Integrations do
  @moduledoc """
  Boundary for external services.

  Product state is committed through Phoenix contexts. Integrations should
  return structured artifacts and never own durable business state.
  """

  import Ecto.Query

  alias Nila.Integrations.Connection
  alias Nila.Repo

  def list_connections(org_id) do
    Repo.all(
      from connection in Connection,
        where: connection.org_id == ^org_id,
        order_by: [asc: connection.provider, asc: connection.external_account_id]
    )
  end

  def get_connection!(id), do: Repo.get!(Connection, id)

  def get_connection(id), do: Repo.fetch(Connection, id)

  def get_connection_by_provider_external_account(provider, external_account_id) do
    Repo.get_by(Connection,
      provider: provider,
      external_account_id: external_account_id,
      status: "active"
    )
  end

  def first_active_connection(org_id, provider) do
    Repo.one(
      from connection in Connection,
        where:
          connection.org_id == ^org_id and connection.provider == ^provider and
            connection.status == "active",
        order_by: [asc: connection.inserted_at],
        limit: 1
    )
  end

  def upsert_connection(attrs) do
    %Connection{}
    |> Connection.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :label,
           :status,
           :credentials,
           :settings,
           :last_synced_at,
           :last_status,
           :last_status_at,
           :last_error,
           :disconnected_at,
           :updated_at
         ]},
      conflict_target: [:org_id, :provider, :external_account_id],
      returning: true
    )
  end

  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.changeset(attrs)
    |> Repo.update()
  end

  def update_credentials(%Connection{} = connection, credentials) when is_map(credentials) do
    connection
    |> Connection.changeset(%{credentials: credentials})
    |> Repo.update()
  end

  def mark_synced(%Connection{} = connection, synced_at \\ DateTime.utc_now()) do
    synced_at = DateTime.truncate(synced_at, :second)

    connection
    |> Connection.changeset(%{
      last_synced_at: synced_at,
      status: "active",
      last_status: "connected",
      last_status_at: synced_at,
      last_error: nil
    })
    |> Repo.update()
  end

  def mark_error(%Connection{} = connection, error, status \\ "error") do
    now = DateTime.utc_now()

    connection
    |> Connection.changeset(%{
      status: "error",
      last_status: status,
      last_status_at: now,
      last_error: error_message(error)
    })
    |> Repo.update()
  end

  def disconnect(%Connection{} = connection) do
    now = DateTime.utc_now()

    connection
    |> Connection.changeset(%{
      status: "disconnected",
      disconnected_at: now,
      last_status_at: now
    })
    |> Repo.update()
  end

  def reconnect(%Connection{} = connection) do
    now = DateTime.utc_now()

    connection
    |> Connection.changeset(%{
      status: "active",
      disconnected_at: nil,
      last_status: "connected",
      last_status_at: now,
      last_error: nil
    })
    |> Repo.update()
  end

  def health_summary(org_id) do
    connections = list_connections(org_id)

    %{
      ok: Enum.count(connections, &(&1.status == "active" and &1.last_status == "connected")),
      degraded:
        Enum.filter(connections, &(&1.status != "active" or &1.last_status != "connected"))
        |> Enum.map(fn connection ->
          %{
            provider: connection.provider,
            label: Connection.display_label(connection),
            last_error: connection.last_error,
            status: connection.status,
            last_status: connection.last_status
          }
        end)
    }
  end

  defp error_message(error) when is_binary(error), do: error
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
