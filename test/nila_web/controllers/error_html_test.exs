defmodule NilaWeb.ErrorHTMLTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.Template, only: [render_to_string: 4]

  test "404 is a complete static document without request assigns" do
    html = render_to_string(NilaWeb.ErrorHTML, "404", "html", [])
    assert html =~ "This page isn’t here."
    assert html =~ ~s(href="/app")
    assert html =~ ~s(name="robots" content="noindex")
    assert html =~ "<!doctype html>"
    refute html =~ "<script"
    refute html =~ "Missing in 2B"
  end

  test "real missing-route pipeline uses the static page", %{conn: conn} do
    html = conn |> get("/definitely/not/a/route") |> response(404)
    assert html =~ "This page isn’t here."
    refute html =~ "/definitely/not/a/route"
    refute html =~ "<script"
  end

  test "500 offers recovery without promising a failed write was rolled back" do
    html = render_to_string(NilaWeb.ErrorHTML, "500", "html", [])
    assert html =~ "We couldn’t load this page."
    assert html =~ "check whether they saved"
    assert html =~ ~s(href="mailto:hello@nila.tax")
    assert html =~ ~s(href="/app")
    refute html =~ "untouched"
    refute html =~ "<script"
  end

  test "other statuses retain the plain text fallback" do
    assert render_to_string(NilaWeb.ErrorHTML, "418", "html", []) == "I&#39;m a teapot"
  end
end
