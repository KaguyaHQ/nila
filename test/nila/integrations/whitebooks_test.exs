defmodule Nila.Integrations.WhitebooksTest do
  use ExUnit.Case, async: false

  alias Nila.Integrations.Whitebooks

  @account %{
    gstin: "33AALCK1118R1Z8",
    username: "gst-user",
    ip_address: "203.0.113.1",
    txn: "session-secret"
  }

  setup do
    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test-id",
      client_secret: "test-secret",
      email: "account@example.test",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)
  end

  test "public lookup sends credentials and account email without GST session headers" do
    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.host == "api.whitebooks.in"
      assert conn.request_path == "/public/search"
      assert conn.query_params == %{"gstin" => @account.gstin, "email" => "account@example.test"}
      assert Plug.Conn.get_req_header(conn, "client_secret") == ["test-secret"]
      assert Plug.Conn.get_req_header(conn, "gst_username") == []
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{"sts" => "Active"}})
    end)

    assert {:ok, %{"data" => %{"sts" => "Active"}}} = Whitebooks.search_taxpayer(@account.gstin)
  end

  test "OTP and session calls use the documented headers and query parameters" do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/otprequest"
      assert Plug.Conn.get_req_header(conn, "gst_username") == [@account.username]
      assert Plug.Conn.get_req_header(conn, "state_cd") == ["33"]
      assert Plug.Conn.get_req_header(conn, "ip_address") == [@account.ip_address]
      assert Plug.Conn.get_req_header(conn, "txn") == []

      Req.Test.json(conn, %{"status_cd" => "1", "status_desc" => "OTP sent", "txn" => "challenge"})
    end)

    assert {:ok, %{"txn" => "challenge"}} = Whitebooks.request_otp(@account)

    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/authentication/authtoken"
      assert conn.query_params["otp"] == "123456"
      assert Plug.Conn.get_req_header(conn, "txn") == [@account.txn]
      Req.Test.json(conn, %{"status_cd" => "1"})
    end)

    assert {:ok, _} = Whitebooks.authenticate(@account, "123456")
  end

  test "notices send the date and case-sensitive reference parameter" do
    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/notices/noticelist"
      assert conn.query_params["date"] == "18/09/2026"
      assert conn.query_params["gstin"] == @account.gstin
      assert Plug.Conn.get_req_header(conn, "txn") == [@account.txn]
      Req.Test.json(conn, %{"status_cd" => "1", "data" => []})
    end)

    assert {:ok, _} = Whitebooks.list_notices(@account, ~D[2026-09-18])

    Req.Test.expect(Whitebooks, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/notices/noticedetails"
      assert conn.query_params["refId"] == "notice/123"
      Req.Test.json(conn, %{"status_cd" => "1", "data" => %{}})
    end)

    assert {:ok, _} = Whitebooks.notice_details(@account, "notice/123")
  end

  test "refresh reuses the GST transaction and transport failures do not leak it" do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/authentication/refreshtoken"
      assert Plug.Conn.get_req_header(conn, "txn") == [@account.txn]
      Req.Test.json(conn, %{"status_cd" => "1", "status_desc" => "Success"})
    end)

    assert {:ok, _} = Whitebooks.refresh(@account)

    Req.Test.expect(Whitebooks, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :unavailable} = Whitebooks.authenticate(@account, "123456")
  end

  test "HTTP 200 with a provider failure is an error without echoed secrets" do
    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{"status_cd" => "0", "status_desc" => "WB_ERR_9101 : test-secret"})
    end)

    assert {:error, {:provider, "WB_ERR_9101"}} = Whitebooks.search_taxpayer(@account.gstin)
  end

  test "unrecognized responses cannot become empty notice lists" do
    Req.Test.expect(Whitebooks, fn conn -> Req.Test.json(conn, %{"data" => []}) end)
    assert {:error, :unexpected_response} = Whitebooks.list_notices(@account, ~D[2026-09-18])
  end

  test "hyphenated GST error codes survive without returning provider descriptions" do
    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{
        "status_cd" => "0",
        "error" => %{
          "errorCode" => "GTR2B-002",
          "errorMessage" => "No record; private-session"
        }
      })
    end)

    assert {:error, {:provider, "GTR2B-002"}} = Whitebooks.gstr2b(@account, ~D[2026-09-01])
  end

  test "GST notice failures use a nested error object" do
    Req.Test.expect(Whitebooks, fn conn ->
      Req.Test.json(conn, %{
        "status_cd" => "0",
        "error" => %{"errorCode" => "NOTC_010", "errorMessage" => "No Records Found."}
      })
    end)

    assert {:error, {:provider, "NOTC_010"}} =
             Whitebooks.list_notices(@account, ~D[2026-09-18])
  end

  test "redirects do not forward credentials and failures are not retried" do
    Req.Test.expect(Whitebooks, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:http, 302}} = Whitebooks.request_otp(@account)

    Req.Test.expect(Whitebooks, fn conn -> Plug.Conn.send_resp(conn, 503, "secret") end)
    assert {:error, {:http, 503}} = Whitebooks.request_otp(@account)
  end

  test "missing configuration and incomplete sessions fail before an HTTP request" do
    assert {:error, :invalid_account} = Whitebooks.request_otp(%{})
    assert {:error, :invalid_account} = Whitebooks.refresh(Map.delete(@account, :txn))
    Application.delete_env(:nila, Whitebooks)
    assert {:error, :not_configured} = Whitebooks.search_taxpayer(@account.gstin)
  end
end
