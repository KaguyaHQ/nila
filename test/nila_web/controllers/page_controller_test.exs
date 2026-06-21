defmodule NilaWeb.PageControllerTest do
  use NilaWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "It does the work."
  end
end
