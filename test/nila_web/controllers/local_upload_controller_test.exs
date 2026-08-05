defmodule NilaWeb.LocalUploadControllerTest do
  use NilaWeb.ConnCase, async: true

  alias Nila.Storage

  @key "orgs/1/dumps/abc/original.pdf"

  defp put_object(conn, token, body, content_type) do
    conn
    |> put_req_header("content-type", content_type)
    |> put(~p"/uploads/local?token=#{token}", body)
  end

  test "writes the body to the key the token carries", %{conn: conn} do
    {:ok, url} = Storage.presign_put(@key)
    token = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")

    conn = put_object(conn, token, "%PDF fixture", "application/pdf")

    assert conn.status == 200
    assert Storage.get(@key) == {:ok, "%PDF fixture"}
  end

  # The endpoint's JSON parser would otherwise decode a portal file, cap it at
  # its 8 MB default, and hand the controller a body already spent. R2 does not
  # parse what it is given, and neither does the thing standing in for it.
  test "a JSON body is stored verbatim rather than parsed", %{conn: conn} do
    key = "orgs/1/dumps/def/original.json"
    {:ok, url} = Storage.presign_put(key)
    token = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")
    body = ~s({"docdata":{"b2b":[]}})

    conn = put_object(conn, token, body, "application/json")

    assert conn.status == 200
    assert Storage.get(key) == {:ok, body}
  end

  # The token is the only authorization, and it is what names the key. A caller
  # who could forge one could write anywhere in the bucket.
  test "refuses a forged token", %{conn: conn} do
    conn = put_object(conn, "not-a-real-token", "%PDF fixture", "application/pdf")

    assert conn.status == 403
  end

  test "refuses a request with no token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/pdf")
      |> put(~p"/uploads/local", "%PDF fixture")

    assert conn.status == 403
  end
end
