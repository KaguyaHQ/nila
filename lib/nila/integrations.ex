defmodule Nila.Integrations do
  @moduledoc """
  Boundary for external services.

  Product state is committed through Phoenix contexts. Integrations should
  return structured artifacts and never own durable business state.
  """

  import Ecto.Query

  alias Nila.Integrations.Connection
  alias Nila.Orgs.Org
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

  def provision_whatsapp(attrs) when is_map(attrs) do
    org_id = attr(attrs, :org_id)
    phone_number_id = attrs |> attr(:phone_number_id) |> normalize_required()
    access_token = attrs |> attr(:access_token) |> normalize_required()
    label = attrs |> attr(:label) |> normalize_optional()

    with true <- is_integer(org_id) and is_binary(phone_number_id) and is_binary(access_token),
         {:ok, _org} <- Repo.fetch(Org, org_id),
         :ok <- whatsapp_account_available(org_id, phone_number_id) do
      now = DateTime.utc_now()

      upsert_connection(%{
        org_id: org_id,
        provider: "whatsapp",
        status: "active",
        last_status: "connected",
        last_status_at: now,
        last_error: nil,
        disconnected_at: nil,
        label: label || "WhatsApp #{phone_number_id}",
        external_account_id: phone_number_id,
        credentials: %{"access_token" => access_token},
        settings: %{}
      })
    else
      false -> {:error, :invalid_whatsapp_connection}
      error -> error
    end
  end

  def first_active_connection(org_id, provider) when is_binary(provider),
    do: first_active_connection(org_id, [provider])

  def first_active_connection(org_id, providers) when is_list(providers) do
    Repo.one(
      from connection in Connection,
        where:
          connection.org_id == ^org_id and connection.provider in ^providers and
            connection.status == "active",
        order_by: [asc: connection.inserted_at],
        limit: 1
    )
  end

  @doc """
  Providers that can deliver an email chase, in preference order.
  """
  def email_providers, do: Connection.email_providers()

  def first_active_email_connection(org_id),
    do: first_active_connection(org_id, email_providers())

  def upsert_connection(attrs) do
    %Connection{}
    |> Connection.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :label,
           :status,
           :tenant_id,
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

  @doc """
  Applies an operator's edits from the connectors screen.

  Scoped to `Connection.settings_changeset/2` so a form can never reach the
  grant or the send-as mailbox.
  """
  def update_connection(%Connection{} = connection, attrs) do
    connection
    |> Connection.settings_changeset(attrs)
    |> Repo.update()
  end

  def update_credentials(%Connection{} = connection, credentials) when is_map(credentials) do
    connection
    |> Connection.changeset(%{credentials: credentials})
    |> Repo.update()
  end

  @doc """
  Returns the connection with a live access token.

  Each provider owns its own token lifecycle: Gmail refreshes an offline grant,
  app-only providers re-mint. The context only asks for a usable connection.
  """
  def ensure_token(%Connection{} = connection) do
    with {:ok, adapter} <- fetch_adapter(connection.provider) do
      adapter.ensure_token(connection)
    end
  end

  @doc """
  Resolves the adapter for a provider.

  A provider can be storable (`Connection.providers/0`) before its adapter
  exists, so this returns an error tuple rather than raising into whichever
  worker happened to pick the connection up.
  """
  def fetch_adapter("gmail"),
    do: {:ok, Application.get_env(:nila, :gmail_adapter, Nila.Integrations.Gmail)}

  def fetch_adapter("microsoft"),
    do: {:ok, Application.get_env(:nila, :microsoft_adapter, Nila.Integrations.Microsoft)}

  def fetch_adapter("whatsapp"),
    do: {:ok, Application.get_env(:nila, :whatsapp_adapter, Nila.Integrations.WhatsApp)}

  def fetch_adapter(provider), do: {:error, {:unsupported_provider, provider}}

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

  def mark_connected(%Connection{} = connection, connected_at \\ DateTime.utc_now()) do
    connected_at = DateTime.truncate(connected_at, :second)

    connection
    |> Connection.changeset(%{
      status: "active",
      last_status: "connected",
      last_status_at: connected_at,
      last_error: nil
    })
    |> Repo.update()
  end

  def mark_degraded(%Connection{} = connection, error) do
    now = DateTime.utc_now()

    connection
    |> Connection.changeset(%{
      status: "active",
      last_status: "error",
      last_status_at: now,
      last_error: error_message(error)
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

  def token_fresh?(%{"access_token" => access_token, "expires_at" => expires_at})
      when is_binary(access_token) and is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} ->
        DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 60)) == :gt

      _error ->
        false
    end
  end

  def token_fresh?(_credentials), do: false

  defp whatsapp_account_available(org_id, phone_number_id) do
    connection =
      Repo.one(
        from connection in Connection,
          where:
            connection.provider == "whatsapp" and
              connection.external_account_id == ^phone_number_id,
          limit: 1
      )

    case connection do
      nil -> :ok
      %Connection{org_id: ^org_id} -> :ok
      %Connection{} -> {:error, :whatsapp_account_already_connected}
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_required(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_required(_value), do: nil

  defp normalize_optional(value), do: normalize_required(value)

  defp error_message(error) when is_binary(error), do: error
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
