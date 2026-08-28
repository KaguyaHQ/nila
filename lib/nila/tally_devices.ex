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
  alias Nila.TallyDevices.CompanyDevice
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

  def list_active_devices(org_id) when is_integer(org_id) do
    Repo.all(
      from device in Device,
        where: device.org_id == ^org_id and is_nil(device.revoked_at),
        order_by: [asc: device.name, asc: device.id]
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
        from(route in CompanyDevice, where: route.device_id == ^device.id)
        |> Repo.update_all(set: [is_open: false, updated_at: seen_at])

        reported =
          Enum.map(companies, fn company ->
            identity = company_identity(company, device.id)

            persisted =
              %Company{
                org_id: device.org_id,
                identity: identity
              }
              |> Company.changeset(company)
              |> Repo.insert!(
                conflict_target: [:org_id, :identity],
                on_conflict: [
                  set: [
                    name: company.name,
                    tally_guid: company.tally_guid,
                    gstin: company.gstin,
                    updated_at: seen_at
                  ]
                ],
                returning: true
              )

            route =
              %CompanyDevice{company_id: persisted.id, device_id: device.id}
              |> CompanyDevice.changeset(%{is_open: true, last_seen_at: seen_at})
              |> Repo.insert!(
                conflict_target: [:company_id, :device_id],
                on_conflict: [
                  set: [is_open: true, last_seen_at: seen_at, updated_at: seen_at]
                ],
                returning: true
              )

            persisted
            |> maybe_link_company_by_gstin()
            |> maybe_add_gstin_to_linked_client()
            |> attach_route(route, device)
          end)

        {:ok, reported}
      end)
    end
  end

  def list_open_companies(org_id, client_id \\ nil) when is_integer(org_id) do
    org_id
    |> list_open_company_routes(client_id)
    |> Enum.uniq_by(& &1.id)
  end

  @doc "Returns one projected company per currently open connector route."
  def list_open_company_routes(org_id, client_id \\ nil) when is_integer(org_id) do
    query =
      from route in CompanyDevice,
        join: company in assoc(route, :company),
        join: device in assoc(route, :device),
        where: company.org_id == ^org_id and route.is_open and is_nil(device.revoked_at),
        order_by: [asc: company.name, desc: route.last_seen_at, asc: device.name],
        preload: [company: company, device: device]

    query =
      if is_integer(client_id) do
        from [route, company, device] in query,
          join: client in Client,
          on: client.active_tally_company_id == company.id,
          where: client.id == ^client_id and client.org_id == ^org_id
      else
        query
      end

    query
    |> Repo.all()
    |> Enum.map(&attach_route(&1.company, &1, &1.device))
  end

  def list_linked_companies(org_id) when is_integer(org_id) do
    companies =
      Repo.all(
        from company in Company,
          join: client in Client,
          on: client.active_tally_company_id == company.id,
          where: company.org_id == ^org_id and client.org_id == ^org_id,
          order_by: [asc: company.name],
          preload: [client: client, device_routes: :device]
      )

    Enum.map(companies, &attach_best_route/1)
  end

  @doc "Returns the Tally company configured as a client's accounting destination."
  def get_client_company(org_id, client_id)
      when is_integer(org_id) and is_integer(client_id) do
    case Repo.fetch_one(
           from company in Company,
             join: client in Client,
             on: client.active_tally_company_id == company.id,
             where:
               company.org_id == ^org_id and client.org_id == ^org_id and client.id == ^client_id,
             preload: [device_routes: :device]
         ) do
      {:ok, company} -> {:ok, attach_best_route(company)}
      error -> error
    end
  end

  def get_client_company(_org_id, _client_id), do: {:error, :not_found}

  def list_importable_companies(org_id) when is_integer(org_id) do
    companies =
      Repo.all(
        from company in Company,
          left_join: client in Client,
          on: client.active_tally_company_id == company.id,
          where: company.org_id == ^org_id and is_nil(client.id),
          order_by: [asc: company.name],
          preload: [device_routes: :device]
      )

    companies
    |> Enum.map(&attach_best_route/1)
    |> Enum.reject(&is_nil(&1.device))
  end

  @doc "Returns the client behind an open Tally company, creating and linking it when needed."
  def ensure_company_client(org_id, company_id)
      when is_integer(org_id) and is_integer(company_id) do
    Repo.transact(fn ->
      with %Company{} = company <-
             Repo.one(
               from company in Company,
                 join: route in assoc(company, :device_routes),
                 join: device in assoc(route, :device),
                 where:
                   company.id == ^company_id and company.org_id == ^org_id and route.is_open and
                     is_nil(device.revoked_at),
                 preload: [:client],
                 limit: 1,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found},
           {:ok, client} <- ensure_company_client_record(company) do
        {:ok, client}
      end
    end)
  end

  def ensure_company_client(_org_id, _company_id), do: {:error, :not_found}

  @doc "Creates a client from an unlinked discovered Tally company and applies its details."
  def create_client_from_company(org_id, company_id, client_attrs)
      when is_integer(org_id) and is_integer(company_id) and is_map(client_attrs) do
    Repo.transact(fn ->
      with %Company{} = company <-
             Repo.one(
               from company in Company,
                 join: route in assoc(company, :device_routes),
                 join: device in assoc(route, :device),
                 where:
                   company.id == ^company_id and company.org_id == ^org_id and
                     is_nil(device.revoked_at),
                 preload: [:client],
                 limit: 1,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found},
           :ok <- company_available_to_client(company.id, nil),
           {:ok, client} <- ensure_company_client_record(company),
           {:ok, client} <- Clients.update_client(client, client_attrs) do
        {:ok, client}
      end
    end)
  end

  def create_client_from_company(_org_id, _company_id, _client_attrs),
    do: {:error, :not_found}

  def update_client_and_link_company(%Client{} = client, company_id, client_attrs)
      when is_integer(company_id) and is_map(client_attrs) do
    Repo.transact(fn ->
      with %Company{} = company <-
             Repo.one(
               from company in Company,
                 join: route in assoc(company, :device_routes),
                 join: device in assoc(route, :device),
                 where:
                   company.id == ^company_id and company.org_id == ^client.org_id and
                     is_nil(device.revoked_at),
                 limit: 1,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found},
           %Client{} = client <-
             Repo.one(
               from locked_client in Client,
                 where: locked_client.id == ^client.id and locked_client.org_id == ^client.org_id,
                 lock: "FOR UPDATE"
             ) || {:error, :not_found},
           :ok <- company_available_to_client(company.id, client.id),
           {:ok, client} <- Clients.update_client(client, client_attrs) do
        client =
          client
          |> Ecto.Changeset.change(active_tally_company_id: company.id)
          |> Repo.update!()

        {:ok, client}
      end
    end)
  end

  def update_client_and_link_company(_client, _company_id, _client_attrs),
    do: {:error, :not_found}

  @doc "Creates or reuses clients for selected discovered companies and links them atomically."
  def import_companies_as_clients(org_id, company_ids)
      when is_integer(org_id) and is_list(company_ids) and company_ids != [] and
             length(company_ids) <= 100 do
    ids = company_ids |> Enum.uniq() |> Enum.sort()

    Repo.transact(fn ->
      open_ids =
        Repo.all(
          from route in CompanyDevice,
            join: company in assoc(route, :company),
            join: device in assoc(route, :device),
            where:
              company.org_id == ^org_id and company.id in ^ids and route.is_open and
                is_nil(device.revoked_at),
            distinct: true,
            select: company.id
        )

      companies =
        Repo.all(
          from company in Company,
            where: company.org_id == ^org_id and company.id in ^open_ids,
            order_by: [asc: company.id],
            lock: "FOR UPDATE"
        )

      unavailable? =
        Repo.exists?(
          from client in Client,
            where: client.active_tally_company_id in ^ids
        )

      if length(companies) != length(ids) or unavailable? do
        {:error, :companies_changed}
      else
        Enum.reduce_while(companies, {:ok, %{created: 0, linked: 0, clients: []}}, fn company,
                                                                                      {:ok, acc} ->
          case find_or_create_client(org_id, company) do
            {:ok, client, disposition} ->
              case client
                   |> Ecto.Changeset.change(active_tally_company_id: company.id)
                   |> Repo.update() do
                {:ok, _client} ->
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

  defp company_available_to_client(company_id, client_id) do
    owner_id =
      Repo.one(
        from client in Client,
          where: client.active_tally_company_id == ^company_id,
          select: client.id
      )

    if is_nil(owner_id) or owner_id == client_id, do: :ok, else: {:error, :not_found}
  end

  def get_open_company(org_id, company_id, client_id \\ nil)

  def get_open_company(org_id, company_id, client_id)
      when is_integer(org_id) and is_integer(company_id) do
    query =
      from route in CompanyDevice,
        join: company in assoc(route, :company),
        join: device in assoc(route, :device),
        where:
          company.id == ^company_id and company.org_id == ^org_id and route.is_open and
            is_nil(device.revoked_at),
        order_by: [desc: route.last_seen_at],
        limit: 1,
        preload: [company: company, device: device]

    query =
      if is_integer(client_id) do
        from [route, company, device] in query,
          join: client in Client,
          on: client.active_tally_company_id == company.id,
          where: client.id == ^client_id and client.org_id == ^org_id
      else
        query
      end

    case Repo.fetch_one(query) do
      {:ok, route} -> {:ok, attach_route(route.company, route, route.device)}
      error -> error
    end
  end

  def get_open_company(_org_id, _company_id, _client_id), do: {:error, :not_found}

  defp ensure_company_client_record(%Company{client: %Client{} = client}), do: {:ok, client}

  defp ensure_company_client_record(%Company{} = company) do
    with {:ok, client, _disposition} <- find_or_create_client(company.org_id, company) do
      client
      |> Ecto.Changeset.change(active_tally_company_id: company.id)
      |> Repo.update!()

      {:ok, client}
    end
  end

  defp find_or_create_client(org_id, %Company{} = company) do
    case client_for_company(org_id, company) do
      %Client{} = client ->
        maybe_add_company_gstin(client, company.gstin)

      nil ->
        attrs = %{org_id: org_id, name: company.name, type: "company", gstin: company.gstin}

        case Clients.create_client(attrs) do
          {:ok, client} -> {:ok, client, :created}
          error -> error
        end
    end
  end

  defp client_for_company(org_id, %Company{gstin: gstin, name: name}) when is_binary(gstin) do
    Repo.one(
      from client in Client,
        where:
          client.org_id == ^org_id and
            fragment("upper(?)", client.gstin) == ^String.upcase(gstin) and
            is_nil(client.active_tally_company_id),
        order_by: [asc: client.id],
        limit: 1
    ) || client_by_name(org_id, gstin, name)
  end

  defp client_for_company(org_id, %Company{name: name}), do: client_by_name(org_id, nil, name)

  defp client_by_name(_org_id, _gstin, nil), do: nil

  defp client_by_name(org_id, gstin, name) do
    case Repo.one(
           from client in Client,
             where:
               client.org_id == ^org_id and
                 fragment("lower(?)", client.name) == ^String.downcase(name) and
                 is_nil(client.active_tally_company_id),
             order_by: [asc: client.id],
             limit: 1
         ) do
      %Client{gstin: existing} = client when is_binary(gstin) and is_binary(existing) ->
        if String.upcase(existing) == String.upcase(gstin), do: client

      client ->
        client
    end
  end

  defp maybe_add_company_gstin(%Client{gstin: nil} = client, gstin) when is_binary(gstin) do
    case Clients.update_client(client, %{gstin: gstin}) do
      {:ok, client} -> {:ok, client, :existing}
      error -> error
    end
  end

  defp maybe_add_company_gstin(%Client{} = client, _gstin), do: {:ok, client, :existing}

  def mark_companies_closed(device_id, now \\ DateTime.utc_now()) when is_integer(device_id) do
    closed_at = DateTime.truncate(now, :microsecond)

    from(route in CompanyDevice,
      where:
        route.device_id == ^device_id and route.is_open and
          route.last_seen_at <= ^closed_at
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
        {:ok,
         normalized
         |> Enum.reverse()
         |> Enum.uniq_by(fn company -> company_identity(company, nil) end)}

      error ->
        error
    end
  end

  defp normalize_companies(_companies), do: {:error, :too_many_companies}

  defp normalize_company(%{"name" => name} = company)
       when is_binary(name) and byte_size(name) <= 200 do
    name = String.trim(name)
    tally_guid = normalize_company_guid(company["tally_guid"])
    gstin = normalize_company_gstin(company["gstin"])

    if name == "" or tally_guid == :invalid or gstin == :invalid do
      {:error, :invalid_company}
    else
      {:ok, %{name: name, tally_guid: tally_guid, gstin: gstin}}
    end
  end

  defp normalize_company(_company), do: {:error, :invalid_company}

  defp normalize_company_guid(nil), do: nil

  defp normalize_company_guid(value) when is_binary(value) and byte_size(value) <= 200 do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_company_guid(_value), do: :invalid

  defp normalize_company_gstin(nil), do: nil

  defp normalize_company_gstin(value) when is_binary(value) and byte_size(value) <= 32 do
    value = value |> String.trim() |> String.upcase()

    cond do
      value == "" -> nil
      Nila.Gstin.valid?(value) -> value
      true -> nil
    end
  end

  defp normalize_company_gstin(_value), do: :invalid

  defp maybe_link_company_by_gstin(%Company{gstin: gstin} = company) when is_binary(gstin) do
    matches =
      Repo.all(
        from client in Client,
          where:
            client.org_id == ^company.org_id and
              fragment("upper(?)", client.gstin) == ^gstin and
              is_nil(client.active_tally_company_id),
          order_by: [asc: client.id],
          limit: 2
      )

    case matches do
      [%Client{} = client] ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        from(candidate in Client,
          where: candidate.id == ^client.id and is_nil(candidate.active_tally_company_id)
        )
        |> Repo.update_all(set: [active_tally_company_id: company.id, updated_at: now])

      _ ->
        :ok
    end

    Repo.preload(company, :client, force: true)
  end

  defp maybe_link_company_by_gstin(%Company{} = company), do: company

  defp maybe_add_gstin_to_linked_client(
         %Company{client: %Client{} = linked_client, gstin: gstin} = company
       )
       when is_binary(gstin) do
    case Repo.get(Client, linked_client.id) do
      %Client{gstin: nil} = client ->
        case Clients.update_client(client, %{gstin: gstin}) do
          {:ok, _client} -> company
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %Client{} ->
        company

      nil ->
        company
    end
  end

  defp maybe_add_gstin_to_linked_client(%Company{} = company), do: company

  defp company_identity(%{tally_guid: tally_guid}, _device_id) when is_binary(tally_guid),
    do: "guid:" <> String.downcase(tally_guid)

  defp company_identity(%{name: name}, device_id),
    do: "device:#{device_id}:name:" <> String.downcase(name)

  defp attach_best_route(%Company{device_routes: routes} = company) when is_list(routes) do
    route =
      routes
      |> Enum.reject(&is_nil(&1.device))
      |> Enum.reject(& &1.device.revoked_at)
      |> Enum.sort_by(
        &{if(&1.is_open, do: 1, else: 0), DateTime.to_unix(&1.last_seen_at, :microsecond)},
        :desc
      )
      |> List.first()

    if route, do: attach_route(company, route, route.device), else: company
  end

  defp attach_route(%Company{} = company, %CompanyDevice{} = route, %Device{} = device) do
    %{
      company
      | device_id: device.id,
        device: device,
        is_open: route.is_open,
        last_seen_at: route.last_seen_at
    }
  end
end
