defmodule NilaWeb.ReactAppControllerTest do
  use NilaWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:nila, :vite_origin)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, :vite_origin, previous),
        else: Application.delete_env(:nila, :vite_origin)
    end)

    :ok
  end

  test "development serves source modules and Fast Refresh without consulting built assets", %{
    conn: conn
  } do
    Application.put_env(:nila, :vite_origin, "http://localhost:5173")
    conn = conn |> init_test_session(%{}) |> NilaWeb.ReactAppController.index(%{})
    body = html_response(conn, 200)
    assert body =~ ~s(src="http://localhost:5173/@vite/client")
    assert body =~ ~s(src="http://localhost:5173/src/main.tsx")
    assert body =~ "__vite_plugin_react_preamble_installed__"
    assert body =~ ~s(name="csrf-token")
    refute body =~ "/frontend/assets/"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "built mode does not include Vite or Fast Refresh", %{conn: conn} do
    Application.delete_env(:nila, :vite_origin)
    conn = conn |> init_test_session(%{}) |> NilaWeb.ReactAppController.index(%{})

    case conn.status do
      200 ->
        body = html_response(conn, 200)
        assert body =~ "/frontend/assets/"
        assert body =~ ~s(name="csrf-token")
        refute body =~ "@vite/client"
        refute body =~ "@react-refresh"

      503 ->
        assert response(conn, 503) =~ "Frontend assets are missing"
    end
  end
end
