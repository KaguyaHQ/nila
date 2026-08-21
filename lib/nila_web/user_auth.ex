defmodule NilaWeb.UserAuth do
  use NilaWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Nila.Accounts
  alias Nila.Accounts.Policy
  alias Nila.Accounts.Scope

  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_nila_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      NilaWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  def log_out_all_user_sessions(conn, user) do
    Accounts.delete_user_session_tokens(user)
    NilaWeb.Endpoint.broadcast(user_sessions_topic(user), "disconnect_user_sessions", %{})
    log_out_user(conn)
  end

  def fetch_current_scope_for_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)

    conn
    |> assign(:current_scope, Scope.for_user(user))
    |> assign(:current_user, user)
  end

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  @doc """
  Tracks the current request path in `:current_path` so the shell can
  highlight the active sidebar entry. Re-runs on every `live_patch` /
  `live_navigate` via the attached `handle_params` hook.
  """
  def on_mount(:mount_current_path, _params, _session, socket) do
    socket =
      Phoenix.LiveView.attach_hook(socket, :mount_current_path, :handle_params, fn
        _params, url, socket ->
          {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(url).path)}
      end)

    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")

      {:halt, socket}
    end
  end

  def on_mount(:require_verified, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    cond do
      is_nil(socket.assigns.current_scope) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}

      verified?(socket.assigns.current_scope) ->
        {:cont, socket}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Verify your email first.")
          |> Phoenix.LiveView.redirect(to: ~p"/users/confirm")

        {:halt, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  def on_mount({:require, capability}, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    authorize(socket, capability)
  end

  def on_mount({:authorize, capability}, _params, _session, socket) do
    authorize(socket, capability)
  end

  defp authorize(socket, capability) do
    scope = socket.assigns[:current_scope]

    cond do
      is_nil(scope) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}

      not verified?(scope) ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Verify your email first.")
          |> Phoenix.LiveView.redirect(to: ~p"/users/confirm")

        {:halt, socket}

      Policy.can?(scope, capability) ->
        {:cont, socket}

      true ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You don't have access to that area.")
          |> Phoenix.LiveView.redirect(to: signed_in_path(socket))

        {:halt, socket}
    end
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

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        with token when not is_nil(token) <- session["user_token"],
             user when not is_nil(user) <- Accounts.get_user_by_session_token(token) do
          Scope.for_user(user)
        end
      end)

    mount_session_disconnect(socket)
  end

  defp mount_session_disconnect(%{assigns: %{current_scope: %Scope{user: user}}} = socket) do
    if Phoenix.LiveView.connected?(socket) do
      NilaWeb.Endpoint.subscribe(user_sessions_topic(user))
    end

    Phoenix.LiveView.attach_hook(socket, :disconnect_user_sessions, :handle_info, fn
      %Phoenix.Socket.Broadcast{event: "disconnect_user_sessions"}, socket ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp mount_session_disconnect(socket), do: socket

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
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
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

  defp signed_in_path(_conn_or_socket), do: ~p"/sales-bills"
end
