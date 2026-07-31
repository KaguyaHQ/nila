defmodule NilaWeb.PageControllerTest do
  use NilaWeb.ConnCase, async: true

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Give us your ten worst clients."
  end

  test "GET /privacy", %{conn: conn} do
    conn = get(conn, ~p"/privacy")
    html = html_response(conn, 200)
    assert html =~ "Privacy policy"
    assert html =~ "WhatsApp communications"
    assert html =~ "WhatsApp Cloud API"
  end

  test "GET /terms", %{conn: conn} do
    conn = get(conn, ~p"/terms")
    html = html_response(conn, 200)
    assert html =~ "Terms of service"
    assert html =~ "Intellectual property"
  end

  test "GET /data-deletion", %{conn: conn} do
    conn = get(conn, ~p"/data-deletion")
    html = html_response(conn, 200)
    assert html =~ "Request data deletion"
    assert html =~ "privacy@nila.tax"
    assert html =~ "legal and regulatory"
    assert html =~ "retention requirements"
  end

  test "GET /contact", %{conn: conn} do
    conn = get(conn, ~p"/contact")
    assert html_response(conn, 200) =~ "hello@nila.tax"
  end
end
