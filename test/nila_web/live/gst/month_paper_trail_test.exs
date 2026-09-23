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

  test "sales uploads show filenames and reopen all files from the same upload", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, batch} = Nila.Gst.Sales.Batch.create(org.id, client.id, Ecto.UUID.generate())

    dumps =
      for name <- ["first.pdf", "second.pdf"] do
        {:ok, dump} =
          Dumps.record(%{org_id: org.id, client_id: client.id, sales_batch_id: batch.id}, %{
            period: @period,
            kind: "sales",
            status: "extracted",
            meta: %{"original_name" => name}
          })

        dump
      end

    batch_ref = Nila.Gst.Sales.Batch.ref(dumps)
    {:ok, view, _} = live(conn, ~p"/gst/#{client.id}/#{@period}/sales/uploads")

    for dump <- dumps do
      assert has_element?(view, "#month-arrived-#{dump.id}", dump.meta["original_name"])

      assert has_element?(
               view,
               "#month-arrived-review-#{dump.id}[href='/sales-bills/#{client.id}/batch/#{batch_ref}']"
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Chase history modal
  # ---------------------------------------------------------------------------

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
end
