defmodule NilaWeb.ErrorHTMLTest do
  use NilaWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  describe "404" do
    # Assign-less on purpose: the dev preview route and the error plug do not
    # supply the same assigns, and the template must render either way.
    test "renders the verdict without a conn" do
      html = render_to_string(NilaWeb.ErrorHTML, "404", "html", [])

      assert html =~ "Not found in the books."
      assert html =~ "Missing in 2B"
      assert html =~ "ITC on this page cannot be claimed."
      assert html =~ ~s(href="/app/clients")
    end

    test "reflects the requested path, capped", %{conn: conn} do
      long = "/gst/" <> String.duplicate("x", 200)

      html =
        render_to_string(NilaWeb.ErrorHTML, "404", "html", conn: %{conn | request_path: long})

      assert html =~ "/gst/xxxx"
      refute html =~ String.duplicate("x", 100)
      assert html =~ "…"
    end

    test "the real pipeline renders it", %{conn: conn} do
      conn = get(conn, "/definitely/not/a/route")

      assert response = response(conn, 404)
      assert response =~ "Not found in the books."
      assert response =~ "/definitely/not/a/route"
      # No socket JS: `render_errors` is `layout: false` and must stay that way.
      refute response =~ "app.js"
    end
  end

  describe "500" do
    test "renders calmly, with no reconciliation joke" do
      html = render_to_string(NilaWeb.ErrorHTML, "500", "html", [])

      assert html =~ "Something broke on our side."
      assert html =~ "Your books are untouched"
      refute html =~ "Missing in 2B"
    end
  end

  test "statuses without a template keep the plain text fallback" do
    assert render_to_string(NilaWeb.ErrorHTML, "418", "html", []) == "I&#39;m a teapot"
  end
end
