defmodule Nila.TallyDevices do
  @moduledoc """
  Device identity boundary for installed Nila Tally connectors.

  A device has one revocable bearer credential. Only its SHA-256 hash is
  persisted; the plaintext token is returned once when the device is created.
  """

  import Ecto.Query

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Orgs.Org
  alias Nila.Repo
  alias Nila.TallyDevices.Company
  alias Nila.TallyDevices.Device
  alias Nila.TallyDevices.Pairing

  @token_bytes 32
  @pairing_lifetime_seconds 600

  def create_device(%Org{} = org, attrs) when is_map(attrs) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    changeset =
      %Device{org_id: org.id, token_hash: hash_token(token)}
      |> Device.changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, device} -> {:ok, device, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_pairing(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    device_code = random_token()
    approval_code = random_token()

    changeset =
      %Pairing{
        device_code_hash: hash_token(device_code),
        approval_code_hash: hash_token(approval_code),
        expires_at: DateTime.add(now, @pairing_lifetime_seconds, :second)
      }
      |> Pairing.changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, pairing} ->
        {:ok,
         %{
           pairing: pairing,
           device_code: device_code,
           approval_code: approval_code,
           expires_in: @pairing_lifetime_seconds
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_pairing_for_approval(approval_code, now \\ DateTime.utc_now())
      when is_binary(approval_code) do
    with {:ok, pairing} <- pairing_by_approval_code(approval_code),
         :ok <- pairing_available_for_approval(pairing, now) do
      {:ok, pairing}
    end
  end

  def approve_pairing(approval_code, scope, now \\ DateTime.utc_now())

  def approve_pairing(
        approval_code,
        %Scope{current_org: %Org{status: "active"} = org, user: user},
        now
      )
      when is_binary(approval_code) do
    Repo.transact(fn ->
      with {:ok, pairing} <- locked_pairing_by_approval_code(approval_code),
           :ok <- pairing_available_for_approval(pairing, now),
           {:ok, approved} <-
             pairing
             |> Ecto.Changeset.change(
               org_id: org.id,
               approved_by_user_id: user.id,
               approved_at: DateTime.truncate(now, :microsecond)
             )
             |> Repo.update() do
        {:ok, approved}
      end
    end)
  end

  def approve_pairing(_approval_code, %Scope{}, _now), do: {:error, :inactive_org}

  def exchange_pairing(device_code, now \\ DateTime.utc_now()) when is_binary(device_code) do
    Repo.transact(fn ->
      with {:ok, pairing} <- locked_pairing_by_device_code(device_code),
           pairing <- Repo.preload(pairing, [:org, :device]),
           {:ok, result} <- exchange_locked_pairing(pairing, device_code, now) do
        {:ok, result}
      end
    end)
  end

  def authenticate_device(token) when is_binary(token) and byte_size(token) <= 256 do
    Repo.one(
      from device in Device,
        join: org in assoc(device, :org),
        where:
          device.token_hash == ^hash_token(token) and is_nil(device.revoked_at) and
            org.status == "active",
        preload: :org
    )
  end

  def authenticate_device(_token), do: nil

  def get_active_device(device_id) when is_integer(device_id) do
    Repo.one(
      from device in Device,
        join: org in assoc(device, :org),
        where: device.id == ^device_id and is_nil(device.revoked_at) and org.status == "active",
        preload: :org
    )
  end

  def mark_connected(%Device{} = device, connected_at \\ DateTime.utc_now()) do
    device
    |> Ecto.Changeset.change(last_connected_at: DateTime.truncate(connected_at, :microsecond))
    |> Repo.update()
  end

  def report_companies(%Device{} = device, companies, now \\ DateTime.utc_now())
      when is_list(companies) do
    with {:ok, companies} <- normalize_companies(companies) do
      seen_at = DateTime.truncate(now, :microsecond)

      Repo.transact(fn ->
        from(company in Company, where: company.device_id == ^device.id)
        |> Repo.update_all(set: [is_open: false, updated_at: seen_at])

        reported =
          Enum.map(companies, fn company ->
            identity = company_identity(company)

            %Company{
              org_id: device.org_id,
              device_id: device.id,
              identity: identity,
              is_open: true,
              last_seen_at: seen_at
            }
            |> Company.changeset(company)
            |> Repo.insert!(
              conflict_target: [:device_id, :identity],
              on_conflict: [
                set: [
                  name: company.name,
                  tally_guid: company.tally_guid,
                  is_open: true,
                  last_seen_at: seen_at,
                  updated_at: seen_at
                ]
              ],
              returning: true
            )
          end)

        {:ok, reported}
      end)
    end
  end

  def list_open_companies(org_id, client_id \\ nil) when is_integer(org_id) do
    query =
      from company in Company,
        join: device in assoc(company, :device),
        where: company.org_id == ^org_id and company.is_open and is_nil(device.revoked_at),
        order_by: [asc: company.name, asc: device.name],
        preload: [device: device]

    query =
      if is_integer(client_id) do
        from company in query, where: company.client_id == ^client_id
      else
        query
      end

    Repo.all(query)
  end

  def list_importable_companies(org_id) when is_integer(org_id) do
    Repo.all(
      from company in Company,
        join: device in assoc(company, :device),
        where:
          company.org_id == ^org_id and company.is_open and is_nil(company.client_id) and
            is_nil(device.revoked_at),
        order_by: [asc: company.name, asc: device.name],
        preload: [device: device]
    )
  end

  @doc "Creates or reuses clients for selected discovered companies and links them atomically."
  def import_companies_as_clients(org_id, company_ids)
      when is_integer(org_id) and is_list(company_ids) and company_ids != [] and
             length(company_ids) <= 100 do
    ids = company_ids |> Enum.uniq() |> Enum.sort()

    Repo.transact(fn ->
      companies =
        Repo.all(
          from company in Company,
            join: device in assoc(company, :device),
            where:
              company.org_id == ^org_id and company.id in ^ids and company.is_open and
                is_nil(company.client_id) and is_nil(device.revoked_at),
            order_by: [asc: company.id],
            lock: "FOR UPDATE"
        )

      if length(companies) != length(ids) do
        {:error, :companies_changed}
      else
        Enum.reduce_while(companies, {:ok, %{created: 0, linked: 0, clients: []}}, fn company,
                                                                                      {:ok, acc} ->
          case find_or_create_client(org_id, company.name) do
            {:ok, client, disposition} ->
              case company |> Ecto.Changeset.change(client_id: client.id) |> Repo.update() do
                {:ok, _company} ->
                  {:cont,
                   {:ok,
                    %{
                      created: acc.created + if(disposition == :created, do: 1, else: 0),
                      linked: acc.linked + if(disposition == :existing, do: 1, else: 0),
                      clients: [client | acc.clients]
                    }}}

                error ->
                  {:halt, error}
              end

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, result} -> {:ok, %{result | clients: Enum.reverse(result.clients)}}
          error -> error
        end
      end
    end)
  end

  def import_companies_as_clients(_org_id, _company_ids), do: {:error, :invalid_companies}

  def get_open_company(org_id, company_id, client_id \\ nil)

  def get_open_company(org_id, company_id, client_id)
      when is_integer(org_id) and is_integer(company_id) do
    query =
      from company in Company,
        join: device in assoc(company, :device),
        where:
          company.id == ^company_id and company.org_id == ^org_id and company.is_open and
            is_nil(device.revoked_at),
        preload: [device: device]

    query =
      if is_integer(client_id) do
        from company in query, where: company.client_id == ^client_id
      else
        query
      end

    Repo.fetch_one(query)
  end

  def get_open_company(_org_id, _company_id, _client_id), do: {:error, :not_found}

  defp find_or_create_client(org_id, name) do
    normalized_name = String.downcase(name)

    case Repo.one(
           from client in Client,
             where:
               client.org_id == ^org_id and
                 fragment("lower(?)", client.name) == ^normalized_name,
             limit: 1
         ) do
      %Client{} = client ->
        {:ok, client, :existing}

      nil ->
        case Clients.create_client(%{org_id: org_id, name: name, type: "company"}) do
          {:ok, client} -> {:ok, client, :created}
          error -> error
        end
    end
  end

  def mark_companies_closed(device_id, now \\ DateTime.utc_now()) when is_integer(device_id) do
    closed_at = DateTime.truncate(now, :microsecond)

    from(company in Company,
      where:
        company.device_id == ^device_id and company.is_open and
          company.last_seen_at <= ^closed_at
    )
    |> Repo.update_all(set: [is_open: false, updated_at: closed_at])

    :ok
  end

  def revoke_device(%Device{} = device, revoked_at \\ DateTime.utc_now()) do
    result =
      device
      |> Ecto.Changeset.change(revoked_at: DateTime.truncate(revoked_at, :microsecond))
      |> Repo.update()

    with {:ok, revoked} <- result do
      disconnect_device(revoked.id)
      {:ok, revoked}
    end
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp random_token,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp pairing_by_approval_code(approval_code) do
    Repo.fetch_one(
      from pairing in Pairing,
        where: pairing.approval_code_hash == ^hash_token(approval_code)
    )
  end

  defp locked_pairing_by_approval_code(approval_code) do
    Repo.fetch_one(
      from pairing in Pairing,
        where: pairing.approval_code_hash == ^hash_token(approval_code),
        lock: "FOR UPDATE"
    )
  end

  defp locked_pairing_by_device_code(device_code) do
    Repo.fetch_one(
      from pairing in Pairing,
        where: pairing.device_code_hash == ^hash_token(device_code),
        lock: "FOR UPDATE"
    )
  end

  defp pairing_available_for_approval(pairing, now) do
    cond do
      pairing.exchanged_at -> {:error, :already_exchanged}
      pairing.approved_at -> {:error, :already_approved}
      DateTime.compare(pairing.expires_at, now) != :gt -> {:error, :expired}
      true -> :ok
    end
  end

  defp exchange_locked_pairing(
         %Pairing{
           device: %Device{revoked_at: nil} = device,
           org: %Org{status: "active"}
         } = pairing,
         device_code,
         _now
       ) do
    {:ok, %{pairing: pairing, device: device, token: device_code}}
  end

  defp exchange_locked_pairing(%Pairing{device: %Device{}}, _device_code, _now),
    do: {:error, :inactive_device}

  defp exchange_locked_pairing(pairing, device_code, now) do
    with :ok <- pairing_available_to_exchange(pairing, now),
         {:ok, device} <- insert_device_from_pairing(pairing),
         {:ok, exchanged} <-
           pairing
           |> Ecto.Changeset.change(
             device_id: device.id,
             exchanged_at: DateTime.truncate(now, :microsecond)
           )
           |> Repo.update() do
      {:ok, %{pairing: exchanged, device: device, token: device_code}}
    end
  end

  defp pairing_available_to_exchange(pairing, now) do
    cond do
      DateTime.compare(pairing.expires_at, now) != :gt -> {:error, :expired}
      is_nil(pairing.approved_at) or is_nil(pairing.org) -> {:error, :pending}
      pairing.org.status != "active" -> {:error, :inactive_org}
      true -> :ok
    end
  end

  defp insert_device_from_pairing(pairing) do
    %Device{org_id: pairing.org.id, token_hash: pairing.device_code_hash}
    |> Device.changeset(%{name: pairing.device_name})
    |> Repo.insert()
  end

  defp disconnect_device(device_id) do
    topic = "tally_device_socket:#{device_id}"

    Phoenix.PubSub.broadcast(
      Nila.PubSub,
      topic,
      %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect", payload: %{}}
    )
  end

  defp normalize_companies(companies) when length(companies) <= 100 do
    companies
    |> Enum.reduce_while({:ok, []}, fn company, {:ok, normalized} ->
      case normalize_company(company) do
        {:ok, company} -> {:cont, {:ok, [company | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok, normalized |> Enum.reverse() |> Enum.uniq_by(&company_identity/1)}

      error ->
        error
    end
  end

  defp normalize_companies(_companies), do: {:error, :too_many_companies}

  defp normalize_company(%{"name" => name} = company)
       when is_binary(name) and byte_size(name) <= 200 do
    name = String.trim(name)
    tally_guid = normalize_company_guid(company["tally_guid"])

    if name == "" or tally_guid == :invalid do
      {:error, :invalid_company}
    else
      {:ok, %{name: name, tally_guid: tally_guid}}
    end
  end

  defp normalize_company(_company), do: {:error, :invalid_company}

  defp normalize_company_guid(nil), do: nil

  defp normalize_company_guid(value) when is_binary(value) and byte_size(value) <= 200 do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_company_guid(_value), do: :invalid

  defp company_identity(%{tally_guid: tally_guid}) when is_binary(tally_guid),
    do: "guid:" <> String.downcase(tally_guid)

  defp company_identity(%{name: name}), do: "name:" <> String.downcase(name)
end
