defmodule NilaWeb.SettingsController do
  use NilaWeb, :controller

  def index(conn, _params) do
    redirect(conn, to: ~p"/settings/workspace")
  end
end
