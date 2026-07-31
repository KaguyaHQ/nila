defmodule NilaWeb.PageController do
  use NilaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def landing(conn, _params) do
    render(conn, :landing, page_title: "Nila — it works while you sleep")
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end

  def data_deletion(conn, _params) do
    render(conn, :data_deletion)
  end

  def contact(conn, _params) do
    render(conn, :contact)
  end
end
