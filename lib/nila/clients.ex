defmodule Nila.Clients do
  @moduledoc """
  The firm's clients — the parties it bills. Bank credits get matched against
  these to answer "who paid me". `match_hints` accumulates known payer
  identities (VPAs, remitter names) so confirmed matches auto-resolve next time.
  """

  import Ecto.Query

  alias Nila.Clients.Client
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

  def create_client(attrs) do
    %Client{}
    |> Client.changeset(attrs)
    |> Repo.insert()
  end

  def update_client(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs)
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
end
