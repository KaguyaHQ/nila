defmodule Nila.Accounts.Scope do
  alias Nila.Accounts.User
  alias Nila.Repo

  defstruct user: nil,
            current_org: nil,
            current_client: nil,
            workspace_navigation: nil,
            membership: nil,
            business_client: nil

  def for_user(nil), do: nil

  # A disabled user has no scope, so an existing session resolves to "logged
  # out" on the next request and the user is bounced to the login page.
  def for_user(%User{active: false}), do: nil

  def for_user(%User{} = user) do
    user = Repo.preload(user, memberships: :org)
    membership = user.memberships |> Enum.sort_by(& &1.id) |> List.first()

    %__MODULE__{
      user: user,
      current_org: membership && membership.org,
      membership: membership,
      business_client:
        if(is_nil(membership),
          do: only_business_client(user.id)
        )
    }
  end

  defp only_business_client(user_id) do
    case Nila.Business.Access.list_clients_for_user(user_id) do
      [client] -> client
      _ -> nil
    end
  end
end
