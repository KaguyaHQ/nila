defmodule Nila.Clients do
  @moduledoc """
  The firm's clients — the parties it bills. Bank credits get matched against
  these to answer "who paid me". `match_hints` accumulates known payer
  identities (VPAs, remitter names) so confirmed matches auto-resolve next time.
  """

  import Ecto.Query

  alias Nila.Clients.Client
  alias Nila.Integrations
  alias Nila.Repo

  def list_clients(org_id) do
    Repo.all(
      from client in Client,
        where: client.org_id == ^org_id,
        order_by: [asc: client.name]
    )
  end

  def get_client(org_id, id) do
    Repo.fetch_one(from client in Client, where: client.org_id == ^org_id and client.id == ^id)
  end

  def get_by_phone(_org_id, nil), do: {:error, :not_found}

  def get_by_phone(org_id, phone) do
    phone = Client.normalize_phone(phone)
    if phone, do: Repo.fetch_by(Client, org_id: org_id, phone: phone), else: {:error, :not_found}
  end

  def get_by_email(_org_id, nil), do: {:error, :not_found}

  def get_by_email(org_id, email) do
    email = Client.normalize_email(email)
    if email, do: Repo.fetch_by(Client, org_id: org_id, email: email), else: {:error, :not_found}
  end

  def create_client(attrs) do
    %Client{}
    |> Client.changeset(attrs)
    |> validate_chase_connection()
    |> Repo.insert()
  end

  def update_client(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs)
    |> validate_chase_connection()
    |> Repo.update()
  end

  def change_client(%Client{} = client, attrs \\ %{}) do
    Client.changeset(client, attrs)
  end

  @doc """
  Records a payer identity (VPA / remitter name) on a client so future credits
  carrying that hint resolve to them automatically.
  """
  def add_match_hint(%Client{} = client, hint) when is_binary(hint) do
    client
    |> Client.changeset(%{match_hints: [hint | client.match_hints]})
    |> Repo.update()
  end

  defp validate_chase_connection(changeset) do
    if Ecto.Changeset.get_change(changeset, :chase_channel) == "email" and
         is_nil(
           Integrations.first_active_connection(
             Ecto.Changeset.get_field(changeset, :org_id),
             "gmail"
           )
         ) do
      Ecto.Changeset.add_error(
        changeset,
        :chase_channel,
        "requires a connected Gmail account — open Settings → Connectors"
      )
    else
      changeset
    end
  end
end
