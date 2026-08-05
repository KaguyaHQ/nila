defmodule Nila.Storage.R2Test do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Nila.Storage.R2

  test "put stores private bytes with content type and byte-size metadata" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/test-bucket/orgs/1/original.pdf"
      assert get_req_header(conn, "content-type") == ["application/pdf"]
      assert get_req_header(conn, "content-length") == ["12"]
      assert get_req_header(conn, "x-amz-meta-byte-size") == ["12"]
      refute get_req_header(conn, "x-amz-acl") == ["public-read"]
      {:ok, body, conn} = read_body(conn)
      assert body == "%PDF fixture"
      send_resp(conn, 200, "")
    end)

    assert {:ok, %{key: "orgs/1/original.pdf", byte_size: 12, content_type: "application/pdf"}} =
             R2.put("orgs/1/original.pdf", "%PDF fixture", content_type: "application/pdf")
  end

  test "get returns object bytes" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/test-bucket/orgs/1/original.pdf"
      send_resp(conn, 200, "%PDF fixture")
    end)

    assert {:ok, "%PDF fixture"} = R2.get("orgs/1/original.pdf", [])
  end

  test "delete removes an object" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/test-bucket/orgs/1/original.pdf"
      send_resp(conn, 204, "")
    end)

    assert :ok = R2.delete("orgs/1/original.pdf", [])
  end

  test "url returns a presigned URL for at most five minutes" do
    url = R2.url("orgs/1/original.pdf", expires_in: 300)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "r2.example.test"
    assert uri.path == "/test-bucket/orgs/1/original.pdf"
    assert query["X-Amz-Expires"] == "300"
    assert query["X-Amz-Signature"]

    assert_raise ArgumentError, fn ->
      R2.url("orgs/1/original.pdf", expires_in: 301)
    end
  end

  # The browser gets this URL and PUTs the bill to it directly. Signing
  # content-type would break the upload whenever the OS names the file's type
  # differently than the entry did, so the signature covers the host only.
  test "presign_put returns a PUT URL the browser can upload to" do
    assert {:ok, url} = R2.presign_put("orgs/1/dumps/abc/original.pdf", [])
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "r2.example.test"
    assert uri.path == "/test-bucket/orgs/1/dumps/abc/original.pdf"
    assert query["X-Amz-Expires"] == "300"
    assert query["X-Amz-Signature"]
    refute query["X-Amz-SignedHeaders"] =~ "content-type"

    assert_raise ArgumentError, fn ->
      R2.presign_put("orgs/1/dumps/abc/original.pdf", expires_in: 301)
    end
  end
end
