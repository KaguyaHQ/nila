defmodule NilaWeb.AssistantLiveTest do
  use NilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nila.Accounts
  alias Nila.Assistant.HTTPClient.Stub
  alias Nila.Assistant.RateLimiter
  alias Nila.Orgs

  setup %{conn: conn} do
    org =
      Orgs.create_org!(%{
        name: "Assistant Live Test Co #{System.unique_integer([:positive])}",
        legal_name: "Assistant Test Private Limited",
        gstin: "29ABCDE1234F1ZW"
      })

    user =
      Accounts.register_user!(%{
        name: "Test User",
        email: "asst-#{System.unique_integer([:positive])}@example.com",
        password: valid_user_password()
      })

    {:ok, _} = Orgs.add_user(org, user.id, "owner")

    Nila.Repo.insert!(%Nila.Documents.Document{
      org_id: org.id,
      storage_key: "test/statement.pdf",
      filename: "statement.pdf",
      byte_size: 1024,
      status: "uploaded",
      document_type: "bank_statement"
    })

    # Allow the LiveView (and its async Tasks) to share the test's DB sandbox.
    Ecto.Adapters.SQL.Sandbox.mode(Nila.Repo, {:shared, self()})

    %{conn: log_in_user(conn, user), user: user, org: org}
  end

  test "mounts with empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/assistant")
    assert html =~ "Ask about your documents"
    assert html =~ "Recent documents"
    refute render(view) =~ "Thinking"
  end

  test "example chips prefill the composer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/assistant")

    html =
      view
      |> element("#assistant-example-recent-documents")
      |> render_click()

    assert html =~ "Show me my recent documents"
  end

  defp text_response(text) do
    {:ok,
     %{
       status: 200,
       body: %{
         "choices" => [
           %{
             "finish_reason" => "stop",
             "message" => %{"role" => "assistant", "content" => text}
           }
         ]
       }
     }}
  end

  defp tool_call_response(call_id, tool_name, args) do
    {:ok,
     %{
       status: 200,
       body: %{
         "choices" => [
           %{
             "finish_reason" => "tool_calls",
             "message" => %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [
                 %{
                   "id" => call_id,
                   "type" => "function",
                   "function" => %{"name" => tool_name, "arguments" => Jason.encode!(args)}
                 }
               ]
             }
           }
         ]
       }
     }}
  end

  test "submitting a message shows user turn, then renders assistant reply", %{conn: conn} do
    Stub.put_responses(text_response("Hello back"))

    {:ok, view, _html} = live(conn, ~p"/assistant")

    html = view |> form("#assistant-form", message: "hi") |> render_submit()
    assert html =~ "hi"

    render_async(view)
    assert render(view) =~ "Hello back"
  end

  test "tool_calls round-trip renders document card", %{conn: conn} do
    Stub.put_responses([
      tool_call_response("call_1", "search_documents", %{}),
      text_response("Found documents.")
    ])

    {:ok, view, _html} = live(conn, ~p"/assistant")

    view |> form("#assistant-form", message: "show documents") |> render_submit()
    render_async(view)
    rendered = render(view)
    assert rendered =~ "Found documents."
    assert rendered =~ "statement.pdf"
  end

  test "empty submission is a no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/assistant")
    html = view |> form("#assistant-form", message: "   ") |> render_submit()
    refute html =~ "Thinking"
  end

  test "rate-limit denial puts a flash and does not call Claude", %{conn: conn, user: user} do
    Stub.put_responses([])

    # Pre-fill the rate-limiter for this user up to the cap (20/min).
    for _ <- 1..20, do: RateLimiter.check_user_message(user)

    {:ok, view, _html} = live(conn, ~p"/assistant")
    html = view |> form("#assistant-form", message: "hi") |> render_submit()
    assert html =~ "Slow down"
  end
end
