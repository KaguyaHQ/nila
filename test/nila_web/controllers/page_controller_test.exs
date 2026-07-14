defmodule NilaWeb.PageControllerTest do
  use NilaWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Give us your ten worst clients."
  end
end
