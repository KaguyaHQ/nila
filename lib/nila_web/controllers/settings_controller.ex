defmodule NilaWeb.SettingsController do
  use NilaWeb, :controller

  def index(conn, _params) do
    if Nila.Accounts.Policy.can?(conn.assigns.current_scope, :manage_settings) do
      redirect(conn, to: ~p"/settings/workspace")
    else
      redirect(conn, to: ~p"/settings/profile")
    end
  end
end
