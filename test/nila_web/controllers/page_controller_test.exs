defmodule NilaWeb.PageControllerTest do
  use NilaWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "It’s done. Review."
    assert html =~ "Arrange a test on WhatsApp"
    assert html =~ "https://wa.me/918148183716"
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
    html = html_response(conn, 200)

    assert html =~ "Give us one filed month."
    assert html =~ "https://wa.me/918148183716"
    assert html =~ ~s(id="callback-form")
    assert html =~ "hello@nila.tax"
  end

  test "POST /contact/callback emails a callback request", %{conn: conn} do
    conn =
      post(conn, ~p"/contact/callback", %{
        "callback" => %{
          "name" => "Anita Raman",
          "firm" => "Raman & Associates",
          "phone" => "+91 98765 43210",
          "website" => ""
        }
      })

    assert redirected_to(conn) == ~p"/contact"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "call you shortly"

    assert_email_sent(fn email ->
      assert email.to == [{"", "hello@nila.tax"}]
      assert email.subject == "New callback request from nila.tax"
      assert email.text_body =~ "Anita Raman"
      assert email.text_body =~ "Raman & Associates"
      assert email.text_body =~ "+91 98765 43210"
    end)
  end

  test "POST /contact/callback renders validation errors", %{conn: conn} do
    conn =
      post(conn, ~p"/contact/callback", %{
        "callback" => %{"name" => "", "firm" => "", "phone" => "12"}
      })

    html = html_response(conn, 422)
    assert html =~ "can&#39;t be blank"
    assert html =~ "must contain between 8 and 15 digits"
    refute_email_sent()
  end

  test "POST /contact/callback silently accepts honeypot submissions", %{conn: conn} do
    conn =
      post(conn, ~p"/contact/callback", %{
        "callback" => %{
          "name" => "Spam Bot",
          "firm" => "Spam",
          "phone" => "9999999999",
          "website" => "https://spam.example"
        }
      })

    assert redirected_to(conn) == ~p"/contact"
    refute_email_sent()
  end

  test "POST /contact/callback shows the WhatsApp fallback when email delivery fails", %{
    conn: conn
  } do
    mailer_config = Application.fetch_env!(:nila, Nila.Mailer)
    Application.put_env(:nila, Nila.Mailer, adapter: Nila.TestFailingMailerAdapter)
    on_exit(fn -> Application.put_env(:nila, Nila.Mailer, mailer_config) end)

    conn =
      post(conn, ~p"/contact/callback", %{
        "callback" => %{
          "name" => "Anita Raman",
          "firm" => "Raman & Associates",
          "phone" => "8111111111"
        }
      })

    html = html_response(conn, 503)
    assert html =~ "We couldn’t request the callback"
    assert html =~ "Arrange on WhatsApp"
    assert html =~ ~s(id="callback-form")
    refute_email_sent()
  end

  test "POST /contact/callback limits repeated requests for one phone" do
    params = %{
      "callback" => %{
        "name" => "Anita Raman",
        "firm" => "Raman & Associates",
        "phone" => "8000000001"
      }
    }

    for _ <- 1..3 do
      assert build_conn() |> post(~p"/contact/callback", params) |> redirected_to() ==
               ~p"/contact"
    end

    conn = post(build_conn(), ~p"/contact/callback", params)
    assert html_response(conn, 429) =~ "Too many callback requests"
  end
end
