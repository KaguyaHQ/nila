defmodule NilaWeb.UserAuth do
  use NilaWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Nila.Accounts
  alias Nila.Accounts.Policy
  alias Nila.Accounts.Scope
  alias Nila.Business.Access
  alias Nila.Clients

  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_nila_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)
    scope = scope_for_user(user, get_session(conn, :current_client_id))
    {conn, workspace_home} = NilaWeb.WorkspaceNavigation.home(conn, scope)

    destination =
      if firm_scope?(scope),
        do: user_return_to || workspace_home,
        else: user_return_to || business_home(user) || workspace_home

    conn
    |> create_user_session(user, params)
    |> redirect(to: destination)
  end

  def create_user_session(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
  end

  def clear_user_session(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
  end

  def log_out_user(conn) do
    conn
    |> clear_user_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/users/log_in")
  end

  def log_out_all_user_sessions(conn, user) do
    conn
    |> clear_all_user_sessions(user)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/users/log_in")
  end

  def clear_all_user_sessions(conn, user) do
    Accounts.delete_user_session_tokens(user)
    NilaWeb.Endpoint.broadcast(user_sessions_topic(user), "disconnect_user_sessions", %{})
    clear_user_session(conn)
  end

  def fetch_current_scope_for_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)

    scope = scope_for_user(user, get_session(conn, :current_client_id))
    {conn, workspace} = NilaWeb.WorkspaceNavigation.read(conn, scope)

    conn =
      if workspace,
        do:
          conn
          |> put_session(:current_client_id, workspace["clientId"])
          |> put_session(:workspace_navigation, workspace),
        else: delete_session(conn, :workspace_navigation)

    scope = if workspace, do: scope_for_user(user, workspace["clientId"]), else: scope
    scope = if scope, do: %{scope | workspace_navigation: workspace}, else: scope

    conn
    |> assign(:current_scope, scope)
    |> assign(:current_user, user)
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  def require_firm_user(conn, _opts) do
    if firm_scope?(conn.assigns[:current_scope]),
      do: conn,
      else: conn |> redirect(to: signed_in_path(conn)) |> halt()
  end

  defp firm_scope?(%Scope{current_org: %{}, membership: %{}}), do: true
  defp firm_scope?(_), do: false

  def require_verified_user(conn, _opts) do
    cond do
      is_nil(conn.assigns[:current_scope]) ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log_in")
        |> halt()

      verified?(conn.assigns.current_scope) ->
        conn

      true ->
        conn
        |> put_flash(:error, "Verify your email first.")
        |> redirect(to: ~p"/users/confirm")
        |> halt()
    end
  end

  @doc """
  Plug that halts unless the current scope holds `capability`. The capability is
  the plug option, e.g. `plug :require_capability, :manage_connectors`.
  """
  def require_capability(conn, capability) do
    cond do
      is_nil(conn.assigns[:current_scope]) ->
        conn
        |> maybe_store_return_to()
        |> redirect(to: ~p"/users/log_in")
        |> halt()

      not verified?(conn.assigns.current_scope) ->
        conn
        |> put_flash(:error, "Verify your email first.")
        |> redirect(to: ~p"/users/confirm")
        |> halt()

      Policy.can?(conn.assigns.current_scope, capability) ->
        conn

      true ->
        conn
        |> put_flash(:error, "You don't have access to that area.")
        |> redirect(to: signed_in_path(conn))
        |> halt()
    end
  end

  defp verified?(%Scope{user: %{confirmed_at: confirmed_at}}), do: not is_nil(confirmed_at)

  defp scope_for_user(nil, _client_id), do: nil
  defp scope_for_user(%Nila.Accounts.User{active: false}, _client_id), do: nil

  defp scope_for_user(user, client_id) do
    scope = Scope.for_user(user)

    current_client =
      with %{current_org: %{id: org_id}} <- scope,
           {:ok, client} <- selected_or_first_client(org_id, client_id) do
        client
      else
        _ -> nil
      end

    %{scope | current_client: current_client}
  end

  defp selected_or_first_client(org_id, client_id) when client_id not in [nil, ""] do
    case Clients.get_client(org_id, client_id) do
      {:ok, client} -> {:ok, client}
      {:error, :not_found} -> first_client(org_id)
    end
  end

  defp selected_or_first_client(org_id, _client_id), do: first_client(org_id)

  defp first_client(org_id) do
    case Clients.list_clients(org_id) do
      [client | _] -> {:ok, client}
      [] -> {:error, :not_found}
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params), do: conn

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp user_sessions_topic(user), do: "users:#{user.id}:sessions"

  defp signed_in_path(%Plug.Conn{} = conn) do
    scope = conn.assigns[:current_scope]

    if firm_scope?(scope),
      do: elem(NilaWeb.WorkspaceNavigation.home(conn, scope), 1),
      else: business_home(conn.assigns[:current_user]) || "/app/clients"
  end

  defp business_home(%{id: user_id}) do
    case Access.list_clients_for_user(user_id) do
      [] -> nil
      [client] -> "/app/business/#{client.id}/invoices"
      _ -> "/app/business"
    end
  end

  defp business_home(_), do: nil
end
