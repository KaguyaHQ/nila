defmodule NilaWeb.GstMonthLiveTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.ClientMonths
  alias Nila.Storage

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    client = client_fixture(org)
    client_month = seed_month(org, client)

    %{
      conn: log_in_user(conn, user),
      org: org,
      client: client,
      client_month: client_month
    }
  end

  test "renders header stats and all register rows from DB data", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gst-month-page")
    assert has_element?(view, "#gst-stat-invoices", "58")
    assert has_element?(view, "#gst-stat-matched", "37")
    assert has_element?(view, "#gst-stat-need-decision", "21")

    rows = read_rows()
    assert length(rows) == 58

    for {row, index} <- Enum.with_index(rows) do
      assert has_element?(view, "##{dom_id(row, index)}")
    end
  end

  test "clicking a row with images shows the bill and reason text", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["images"] not in [nil, []] and row["flags"] not in [nil, []]
      end)

    view |> element("##{dom_id(row, index)}") |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    assert has_element?(view, "#gst-evidence-images img")
    reason = row["flags"] |> hd() |> Map.get("reason")
    assert render(view) =~ reason
  end

  test "clicking a 2B-only row shows its note without an image", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} -> row["images"] in [nil, []] and row["recon_note"] end)

    view |> element("##{dom_id(row, index)}") |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    refute has_element?(view, "#gst-evidence-images img")
    assert render(view) =~ row["recon_note"]
  end

  test "the owning org can fetch an evidence image", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "another org cannot fetch this org's evidence image", %{client: client} do
    %{user: other_user} = user_with_org_fixture(%{org: %{gstin: "27ZZZZZ9999Z1ZP"}})
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 404)
  end

  test "evidence rejects a basename outside the image whitelist", %{
    conn: conn,
    client: client
  } do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/#{"secret.txt"}")

    assert response(conn, 404)
  end

  test "redirects logged-out visitors to log in", %{client: client} do
    assert {:error, {:redirect, %{to: "/users/log_in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/gst/#{client.id}/#{@period}")
  end

  defp client_fixture(org) do
    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    client
  end

  defp seed_month(org, client) do
    for basename <- File.ls!(Path.join(@dir, "images")) do
      bytes = File.read!(Path.join([@dir, "images", basename]))
      key = ClientMonths.evidence_key(org.id, client.id, @period, basename)
      {:ok, _} = Storage.put(key, bytes)
    end

    {:ok, client_month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: read_rows(),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    client_month
  end

  defp read_rows, do: read_json("register_rows.json")

  defp read_json(file) do
    @dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp dom_id(%{"id" => id}, _index) when is_binary(id), do: "gst-row-#{id}"
  defp dom_id(_row, index), do: "gst-row-idx-#{index}"
end
