defmodule Nila.TallyDevices do
  @moduledoc """
  Device identity boundary for installed Nila Tally connectors.

  A device has one revocable bearer credential. Only its SHA-256 hash is
  persisted; the plaintext token is returned once when the device is created.
  """

  import Ecto.Query

  alias Nila.Accounts.Scope
  alias Nila.Orgs.Org
  alias Nila.Repo
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
end
