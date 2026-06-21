defmodule NilaWeb.PageController do
  use NilaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
