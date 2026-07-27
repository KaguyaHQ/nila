defmodule NilaWeb.Gst.MonthPaperTrailTest do
  @moduledoc """
  The month's paper trail: originals downloadable, every arrival visible on
  the month page, and the chase asks readable verbatim — months later, from
  the one room that exists for every month.
  """
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Storage

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    {:ok, _month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{"buckets" => %{"matched" => 0}}
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp seed_dump(org, client, kind, opts \\ []) do
    ext = Keyword.get(opts, :ext, ".pdf")
    bytes = Keyword.get(opts, :bytes, "%PDF-1.4 original")

    key =
      "dumps/#{org.id}/#{client.id}/#{@period}/#{kind}_#{System.unique_integer([:positive])}#{ext}"

    {:ok, _} = Storage.put(key, bytes)

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: opts[:user_id]},
        %{period: @period, kind: kind, source: opts[:source], file_keys: [key]}
      )

    Dumps.mark_extracted(dump, [])
  end

  # ---------------------------------------------------------------------------
  # Originals downloadable
  # ---------------------------------------------------------------------------

  test "the owning org downloads a dump's original with a human filename", %{
    conn: conn,
    org: org,
    client: client
  } do
    dump = seed_dump(org, client, "purchase")

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/0")

    assert response(conn, 200) == "%PDF-1.4 original"
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/pdf"

    assert get_resp_header(conn, "content-disposition") |> hd() ==
             ~s(attachment; filename="Breeze Tech 2025-10 purchase bills.pdf")
  end

  test "a 2B original downloads as JSON", %{conn: conn, org: org, client: client} do
    dump = seed_dump(org, client, "gstr2b", ext: ".json", bytes: ~s({"docdata":{}}))

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/0")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "GSTR-2B.json"
  end

  test "logged-out visitors cannot download originals", %{org: org, client: client} do
    dump = seed_dump(org, client, "purchase")

    conn =
      get(
        Phoenix.ConnTest.build_conn(),
        ~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/0"
      )

    assert redirected_to(conn) == "/users/log_in"
  end

  test "another org cannot download this org's original", %{org: org, client: client} do
    dump = seed_dump(org, client, "purchase")

    %{user: other_user} = user_with_org_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), other_user)

    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/0")
    assert response(conn, 404)
  end

  test "a wrong dump id, mismatched period, or bad index 404s", %{
    conn: conn,
    org: org,
    client: client
  } do
    dump = seed_dump(org, client, "purchase")

    assert conn |> get(~p"/gst/#{client.id}/#{@period}/original/999999/0") |> response(404)
    assert conn |> get(~p"/gst/#{client.id}/2024-01/original/#{dump.id}/0") |> response(404)
    assert conn |> get(~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/5") |> response(404)
    assert conn |> get(~p"/gst/#{client.id}/#{@period}/original/#{dump.id}/nope") |> response(404)
  end

  test "storage objects are not served through the public static path", %{
    org: org,
    client: client
  } do
    dump = seed_dump(org, client, "purchase")
    [key] = dump.file_keys

    conn = get(Phoenix.ConnTest.build_conn(), "/uploads/#{key}")

    assert response(conn, 404)
  end

  # ---------------------------------------------------------------------------
  # The month page shows every arrival
  # ---------------------------------------------------------------------------

  test "a processed dump renders in the Arrived list with a download link", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    dump = seed_dump(org, client, "purchase", user_id: user.id, source: "whatsapp")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-arrived-#{dump.id}", "Purchase bills")
    assert has_element?(view, "#month-arrived-#{dump.id}", "1 file")
    assert has_element?(view, "#month-arrived-#{dump.id}", "brought in by Test User")
    assert has_element?(view, "#month-arrived-#{dump.id}", "over WhatsApp")

    assert has_element?(
             view,
             "#month-arrived-file-#{dump.id}-0[href='/gst/#{client.id}/#{@period}/original/#{dump.id}/0']"
           )

    refute has_element?(view, "#month-dump-#{dump.id}")
  end

  test "a replaced 2B renders both dumps, the old one marked", %{
    conn: conn,
    org: org,
    client: client
  } do
    old = seed_dump(org, client, "gstr2b", ext: ".json")
    new = seed_dump(org, client, "gstr2b", ext: ".json")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-arrived-#{old.id}", "(replaced)")
    assert has_element?(view, "#month-arrived-#{old.id} .line-through")
    assert has_element?(view, "#month-arrived-#{new.id}")
    refute has_element?(view, "#month-arrived-#{new.id}", "(replaced)")
  end

  test "a month with no dumps renders no Arrived shell", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#month-arrived")
  end

  # ---------------------------------------------------------------------------
  # Chase history modal
  # ---------------------------------------------------------------------------

  test "the month page links the chase history only when asks exist", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    seed_dump(org, client, "purchase")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    refute has_element?(view, "#month-chase-history-link")

    {:ok, manual} =
      Chase.record_ask(
        %{org_id: org.id, client_id: client.id, sent_by_id: user.id},
        %{kind: "month_open", period: @period, body: "Hi Breeze Tech,\n\nplease send the bills."}
      )

    {:ok, auto} =
      Chase.record_ask(
        %{org_id: org.id, client_id: client.id},
        %{
          kind: "missing_bills",
          period: @period,
          body: "Sharma Steels — invoice INV-042, ₹11,800.00",
          channel: "whatsapp"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert has_element?(view, "#month-chase-history-link", "Asked 2×, see what we sent")

    view |> element("#month-chase-history-link") |> render_click()

    assert has_element?(view, "#month-chase-history-modal")
    assert has_element?(view, "#chase-ask-#{manual.id}", "Manual")
    assert has_element?(view, "#chase-ask-#{manual.id}", "Month open")
    assert has_element?(view, "#chase-ask-#{manual.id}", "sent by Test User")
    assert has_element?(view, "#chase-ask-#{auto.id}", "WhatsApp")
    assert has_element?(view, "#chase-ask-#{auto.id}", "Missing bills")
    assert has_element?(view, "#chase-ask-#{auto.id}", "sent by Nila")

    body = view |> element("#chase-ask-#{manual.id} pre") |> render()
    assert body =~ "Hi Breeze Tech,\n\nplease send the bills."
    assert render(view) =~ "Sharma Steels — invoice INV-042, ₹11,800.00"
  end

  test "Today's ask label opens the same chase history", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    {:ok, ask} =
      Chase.record_ask(
        %{org_id: org.id, client_id: client.id, sent_by_id: user.id},
        %{kind: "month_open", period: @period, body: "Hi Breeze Tech, send the bills."}
      )

    {:ok, view, _html} = live(conn, ~p"/today")

    view |> element("#last-ask-#{client.id}-#{@period}") |> render_click()

    assert has_element?(view, "#today-chase-history-modal")
    assert has_element?(view, "#chase-ask-#{ask.id}", "sent by Test User")
    assert render(view) =~ "Hi Breeze Tech, send the bills."
  end

  # ---------------------------------------------------------------------------
  # Tenancy
  # ---------------------------------------------------------------------------

  test "another org's dumps and asks never render on this org's month", %{
    conn: conn,
    org: org,
    client: client,
    user: user
  } do
    %{org: other_org, user: other_user} = user_with_org_fixture()

    {:ok, other_client} =
      Clients.create_client(%{org_id: other_org.id, name: "Rival Corp", type: "company"})

    foreign_dump = seed_dump(other_org, other_client, "purchase", user_id: other_user.id)

    {:ok, _} =
      Chase.record_ask(
        %{org_id: other_org.id, client_id: other_client.id, sent_by_id: other_user.id},
        %{kind: "month_open", period: @period, body: "Rival secret ask body."}
      )

    own_dump = seed_dump(org, client, "purchase", user_id: user.id)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-arrived-#{own_dump.id}")
    refute has_element?(view, "#month-arrived-#{foreign_dump.id}")
    refute has_element?(view, "#month-chase-history-link")
    refute render(view) =~ "Rival secret ask body."
  end
end
