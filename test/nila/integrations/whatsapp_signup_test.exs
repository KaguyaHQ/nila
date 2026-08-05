defmodule Nila.Integrations.WhatsAppSignupTest do
  # Synchronous: the allowlist tests move `:allowed_business_id` in app env,
  # which `configured?/0` reads from other suites.
  use ExUnit.Case, async: false

  alias Nila.Integrations.{Connection, WhatsAppSignup}

  @session %{
    "business_id" => "111111111",
    "waba_id" => "222222222",
    "phone_number_id" => "333333333"
  }

  test "exchanges the code, verifies Graph assets, subscribes, and registers the phone" do
    Req.Test.expect(WhatsAppSignup, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/v26.0/oauth/access_token"
      assert conn.params["client_id"] == "123456789"
      assert conn.params["client_secret"] == "test-whatsapp-app-secret"
      assert conn.params["code"] == "authorization-code"

      Req.Test.json(conn, %{
        "access_token" => "business-token",
        "token_type" => "bearer",
        "expires_in" => 3600
      })
    end)

    expect_graph_get("/v26.0/me", %{"client_business_id" => "111111111"})

    expect_graph_get("/v26.0/222222222", %{
      "id" => "222222222",
      "name" => "Firm WABA",
      "account_review_status" => "APPROVED",
      "business_verification_status" => "verified"
    })

    expect_graph_get("/v26.0/222222222/phone_numbers", %{
      "data" => [phone_payload()]
    })

    Req.Test.expect(WhatsAppSignup, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v26.0/222222222/subscribed_apps"
      assert_bearer(conn)
      Req.Test.json(conn, %{"success" => true})
    end)

    expect_graph_get("/v26.0/222222222/subscribed_apps", %{
      "data" => [%{"whatsapp_business_api_data" => %{"id" => "123456789"}}]
    })

    Req.Test.expect(WhatsAppSignup, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v26.0/333333333/register"
      assert_bearer(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["messaging_product"] == "whatsapp"
      assert payload["pin"] =~ ~r/^\d{6}$/
      Req.Test.json(conn, %{"success" => true})
    end)

    expect_graph_get("/v26.0/222222222/phone_numbers", %{
      "data" => [phone_payload()]
    })

    assert {:ok, signup} = WhatsAppSignup.complete_signup("authorization-code", @session)
    assert signup.business_id == "111111111"
    assert signup.waba_id == "222222222"
    assert signup.phone_number_id == "333333333"
    assert signup.display_phone_number == "+91 98765 43210"
    assert signup.webhook_subscribed
    assert signup.registered
    assert signup.two_step_pin =~ ~r/^\d{6}$/
    assert is_binary(signup.expires_at)
  end

  test "rejects malformed browser asset IDs before making Graph calls" do
    assert {:error, :invalid_whatsapp_signup_session} =
             WhatsAppSignup.complete_signup("authorization-code", %{
               "business_id" => "111111111",
               "waba_id" => "not-an-id",
               "phone_number_id" => "333333333"
             })
  end

  test "returns token exchange errors without making asset calls" do
    Req.Test.expect(WhatsAppSignup, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "expired code"}})
    end)

    assert {:error,
            {:whatsapp_token_exchange_failed, 400, %{"error" => %{"message" => "expired code"}}}} =
             WhatsAppSignup.complete_signup("expired-code", @session)
  end

  test "rejects a phone that Graph does not place in the selected WABA" do
    expect_token_exchange()
    expect_business_and_waba()
    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => []})

    assert {:error, :whatsapp_phone_number_mismatch} =
             WhatsAppSignup.complete_signup("authorization-code", @session)
  end

  test "requires subscription readback to include Nila's app" do
    expect_token_exchange()
    expect_business_and_waba()
    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => [phone_payload()]})

    Req.Test.expect(WhatsAppSignup, fn conn ->
      Req.Test.json(conn, %{"success" => true})
    end)

    expect_graph_get("/v26.0/222222222/subscribed_apps", %{"data" => []})

    assert {:error, :whatsapp_subscription_not_confirmed} =
             WhatsAppSignup.complete_signup("authorization-code", @session)
  end

  test "returns phone registration failures without persisting readiness" do
    expect_token_exchange()
    expect_business_and_waba()
    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => [phone_payload()]})

    Req.Test.expect(WhatsAppSignup, fn conn ->
      Req.Test.json(conn, %{"success" => true})
    end)

    expect_graph_get("/v26.0/222222222/subscribed_apps", %{
      "data" => [%{"id" => "123456789"}]
    })

    Req.Test.expect(WhatsAppSignup, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "registration failed"}})
    end)

    assert {:error,
            {:whatsapp_registration_failed, 400,
             %{"error" => %{"message" => "registration failed"}}}} =
             WhatsAppSignup.complete_signup("authorization-code", @session)
  end

  test "rejects a browser business that does not match the token business" do
    Req.Test.expect(WhatsAppSignup, fn conn ->
      Req.Test.json(conn, %{"access_token" => "business-token"})
    end)

    expect_graph_get("/v26.0/me", %{"client_business_id" => "999999999"})

    assert {:error, :whatsapp_business_mismatch} =
             WhatsAppSignup.complete_signup("authorization-code", @session)
  end

  test "onboards a business Nila has never seen when no allowlist is configured" do
    session = %{@session | "business_id" => "555555555"}

    expect_token_exchange()
    expect_graph_get("/v26.0/me", %{"client_business_id" => "555555555"})

    expect_graph_get("/v26.0/222222222", %{
      "id" => "222222222",
      "name" => "Customer WABA",
      "account_review_status" => "APPROVED",
      "business_verification_status" => "verified"
    })

    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => [phone_payload()]})

    Req.Test.expect(WhatsAppSignup, fn conn -> Req.Test.json(conn, %{"success" => true}) end)
    expect_graph_get("/v26.0/222222222/subscribed_apps", %{"data" => [%{"id" => "123456789"}]})
    Req.Test.expect(WhatsAppSignup, fn conn -> Req.Test.json(conn, %{"success" => true}) end)
    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => [phone_payload()]})

    assert {:ok, signup} = WhatsAppSignup.complete_signup("authorization-code", session)
    assert signup.business_id == "555555555"
  end

  test "still requires the pinned business when an allowlist is configured" do
    pin_allowed_business("111111111")

    session = %{@session | "business_id" => "555555555"}

    expect_token_exchange()
    expect_graph_get("/v26.0/me", %{"client_business_id" => "555555555"})

    assert {:error, :whatsapp_business_mismatch} =
             WhatsAppSignup.complete_signup("authorization-code", session)
  end

  test "is configured without an allowlist" do
    assert WhatsAppSignup.configured?()
    assert {:ok, %{app_id: "123456789", config_id: "987654321"}} = WhatsAppSignup.public_config()
  end

  test "verifies an existing connection without sending a message" do
    expect_graph_get("/v26.0/me", %{"client_business_id" => "111111111"})

    expect_graph_get("/v26.0/222222222", %{
      "id" => "222222222",
      "name" => "Firm WABA",
      "account_review_status" => "APPROVED",
      "business_verification_status" => "verified"
    })

    expect_graph_get("/v26.0/222222222/phone_numbers", %{"data" => [phone_payload()]})

    expect_graph_get("/v26.0/222222222/subscribed_apps", %{
      "data" => [%{"id" => "123456789"}]
    })

    connection = %Connection{
      external_account_id: "333333333",
      credentials: %{"access_token" => "business-token"},
      settings: %{"business_id" => "111111111", "waba_id" => "222222222"}
    }

    assert {:ok, metadata} = WhatsAppSignup.verify_connection(connection)
    assert metadata["phone_status"] == "CONNECTED"
    assert metadata["webhook_subscribed"]
    assert is_binary(metadata["readiness_checked_at"])
  end

  defp pin_allowed_business(business_id) do
    config = Application.get_env(:nila, WhatsAppSignup, [])

    Application.put_env(
      :nila,
      WhatsAppSignup,
      Keyword.put(config, :allowed_business_id, business_id)
    )

    on_exit(fn -> Application.put_env(:nila, WhatsAppSignup, config) end)
  end

  defp expect_token_exchange do
    Req.Test.expect(WhatsAppSignup, fn conn ->
      Req.Test.json(conn, %{"access_token" => "business-token", "token_type" => "bearer"})
    end)
  end

  defp expect_business_and_waba do
    expect_graph_get("/v26.0/me", %{"client_business_id" => "111111111"})

    expect_graph_get("/v26.0/222222222", %{
      "id" => "222222222",
      "name" => "Firm WABA",
      "account_review_status" => "APPROVED",
      "business_verification_status" => "verified"
    })
  end

  defp expect_graph_get(path, response) do
    Req.Test.expect(WhatsAppSignup, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == path
      assert_bearer(conn)
      Req.Test.json(conn, response)
    end)
  end

  defp assert_bearer(conn) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer business-token"]
  end

  defp phone_payload do
    %{
      "id" => "333333333",
      "display_phone_number" => "+91 98765 43210",
      "verified_name" => "Firm WhatsApp",
      "quality_rating" => "GREEN",
      "code_verification_status" => "VERIFIED",
      "status" => "CONNECTED"
    }
  end
end
