defmodule NilaWeb.MonthLivePurchaseTest do
  use NilaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.{Calendar, ClientMonths, Dumps, SalesMonths, Signoffs}
  alias Nila.Storage

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    client = client_fixture(org)
    client_month = seed_month(org, client)

    %{
      conn: log_in_user(conn, user),
      user: user,
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

    assert has_element?(view, "#month-page")
    assert has_element?(view, "#gst-stat-invoices", "58")
    assert has_element?(view, "#gst-stat-matched", "37")
    assert has_element?(view, "#gst-stat-need-decision", "21")
    assert has_element?(view, "#gst-stats", "need a decision")
    assert has_element?(view, "#gst-register", "Needs a decision")
    refute render(view) =~ "Needs review"
    assert has_element?(view, "#month-decide-purchases", "Decide 21 purchases →")

    rows = read_rows()
    assert length(rows) == 58

    for {row, index} <- Enum.with_index(rows) do
      assert has_element?(view, "##{dom_id(row, index)}")
    end
  end

  test "the spine shows each step's state and jumps to its section", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-spine")
    assert has_element?(view, "#spine-inputs", "partial")
    assert has_element?(view, "#spine-gstr1", "missing")
    assert has_element?(view, "#spine-purchases", "21 to decide")
    assert has_element?(view, "#spine-gstr3b", "waiting")
    assert view |> element("#spine-purchases") |> render() =~ ~s(href="#month-purchases")
    assert view |> element("#spine-gstr1") |> render() =~ ~s(href="#month-sales-missing")
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

    reason = row["flags"] |> hd() |> Map.get("reason")
    verdict = row["flags"] |> hd() |> Map.get("code") |> Nila.Formatters.issue_label()
    selector = "##{dom_id(row, index)}"

    refute has_element?(view, "#gst-register #{selector}", reason)
    assert has_element?(view, "#gst-register #{selector} .truncate", verdict)

    view |> element(selector) |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    assert has_element?(view, "#gst-evidence-images img")
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

    selector = "##{dom_id(row, index)}"
    refute has_element?(view, "#gst-register #{selector}", row["recon_note"])

    assert has_element?(
             view,
             "#gst-register #{selector} .truncate",
             "Ask the client for this bill"
           )

    view |> element(selector) |> render_click()

    assert has_element?(view, "#gst-evidence-modal")
    refute has_element?(view, "#gst-evidence-images img")
    assert render(view) =~ row["recon_note"]
  end

  test "the 3B panel shows the ITC side and says the liability is missing", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gst-3b-panel")
    html = render(view)
    assert html =~ "outward liability needs the month"
    assert html =~ "C Net ITC"
    refute has_element?(view, "#gst-3b-cash")
  end

  test "the sales section renders on the same page when a sales month exists", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert has_element?(view, "#month-sales-missing")
    refute has_element?(view, "#month-sales")

    {:ok, _} =
      Nila.Gst.SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        invoices: [],
        derived_gstr1: %{},
        issues: [],
        summary: %{}
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-sales")
    refute has_element?(view, "#month-sales-missing")
  end

  test "the owning org can fetch an evidence image", %{conn: conn, client: client} do
    conn = get(conn, ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "logged-out visitors cannot fetch evidence", %{client: client} do
    conn =
      get(Phoenix.ConnTest.build_conn(), ~p"/gst/#{client.id}/#{@period}/evidence/page_09.png")

    assert redirected_to(conn) == "/users/log_in"
  end

  test "another org cannot fetch this org's evidence image", %{client: client} do
    %{user: other_user} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})
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

  test "a dump after filing points to the open month and cannot be released", %{
    conn: conn,
    user: user,
    org: org,
    client: client
  } do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: @period, kind: "purchase", file_keys: ["late/purchase.pdf"]}
      )

    dump = Dumps.mark_after_filing(dump)
    open_period = Calendar.closeable_period(Date.utc_today())

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#month-dump-#{dump.id}", "Arrived after this month was filed")
    assert has_element?(view, "#month-dump-#{dump.id}", "a filed return can't change")

    assert has_element?(
             view,
             "#month-dump-open-period-#{dump.id}[href='/gst/upload?client_id=#{client.id}&period=#{open_period}']",
             "Bring it into the open month →"
           )

    refute has_element?(view, "#month-dump-release-#{dump.id}")
    refute has_element?(view, "#month-dump-#{dump.id}", "reopen")
  end

  test "owner signs off: banner appears and the month moves to reviewed", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#gst-signoff-button")
    assert has_element?(view, "#gst-signoff-blocked", "21 purchases to decide")
    assert has_element?(view, "#gst-signoff-blocked", "the sales bills")

    {:ok, _sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed",
        invoices: []
      })

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    clean_recon =
      month.recon
      |> Map.put("needs_human", [])
      |> Map.put("in_2b_not_books", [])
      |> Map.put("in_books_not_2b", [])

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: month.register_rows,
        recon: clean_recon,
        summary: month.summary
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gst-signoff-button")
    view |> element("#gst-signoff-button") |> render_click()

    assert has_element?(view, "#gst-signoff-banner")
    assert has_element?(view, "#month-file-gstr3b[href='#gst-signoff-banner']")
    assert has_element?(view, "#gst-signoff-banner a[target='_blank'][rel='noopener']")
    assert has_element?(view, "#gst-filed-arn[autofocus]")
    refute has_element?(view, "#gst-signoff-button")
    assert render(view) =~ "Signed off by"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "reviewed"
    assert {:ok, signoff} = Signoffs.latest_signoff(month.id)
    assert Map.has_key?(signoff.snapshot, "gstr3b")
  end

  test "a clean worked month points seniors to sign-off and tells members to wait", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, _purchase} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{},
        summary: %{"buckets" => %{"matched" => 0}}
      })

    {:ok, _sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")
    assert has_element?(view, "#month-ready-signoff[href='#month-sales']")

    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    member_conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, member_view, _html} = live(member_conn, ~p"/gst/#{client.id}/#{@period}")
    assert render(member_view) =~ "Worked and clean — a senior will see it on their Today."
  end

  test "a signed month renders from the frozen snapshot, not live derivation", %{
    conn: conn,
    client: client,
    org: org,
    user: user
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    scope = Nila.Accounts.Scope.for_user(user)
    {:ok, _} = Signoffs.sign_off(month, scope)
    {:ok, signoff} = Signoffs.latest_signoff(month.id)

    frozen = put_in(signoff.snapshot, ["summary", "buckets", "matched"], 999)

    signoff
    |> Ecto.Changeset.change(snapshot: frozen)
    |> Nila.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#gst-signoff-banner")
    assert has_element?(view, "#gst-stat-matched", "999")
  end

  test "filing the second return closes the month and points back to Today", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)
    assert {:ok, _} = Signoffs.mark_filed(sales, scope, "R1-ARN")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view
    |> element("#gst-mark-filed")
    |> render_submit(%{"arn" => "3B-ARN"})

    assert render(view) =~ "Month closed."
    assert has_element?(view, "#month-strip", "Month closed — GSTR-1 and GSTR-3B filed.")
    assert has_element?(view, "#month-back-today", "Back to Today")
    assert has_element?(view, ~s|#month-view-register[href="/register"]|, "View the register →")

    assert has_element?(view, "#spine-inputs", "in")
    assert has_element?(view, "#spine-gstr1", "filed")
    assert has_element?(view, "#spine-gstr3b", "filed")
    refute has_element?(view, "#month-deadline")
  end

  test "a signed-unfiled month shows signed spine steps and an overdue-since deadline", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    assert has_element?(view, "#spine-gstr1", "signed")
    assert has_element?(view, "#spine-gstr3b", "signed")
    assert has_element?(view, "#month-deadline", "overdue since 11 Nov 2025")
  end

  test "matched rows without flags render a silent note column", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    {row, index} =
      read_rows()
      |> Enum.with_index()
      |> Enum.find(fn {row, _} ->
        row["bucket"] == "matched" and row["flags"] in [nil, []]
      end)

    refute view |> element("##{dom_id(row, index)}") |> render() =~ "matched on"
  end

  test "filing GSTR-1 second also closes the month", %{
    conn: conn,
    org: org,
    user: user,
    client: client,
    client_month: client_month
  } do
    {:ok, sales} =
      SalesMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "reviewed"
      })

    scope = Nila.Accounts.Scope.for_user(user)
    assert {:ok, _} = Signoffs.sign_off_gstr1(sales, scope)
    assert {:ok, _} = Signoffs.sign_off(client_month, scope)
    assert {:ok, _} = Signoffs.mark_filed(client_month, scope, "3B-ARN")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    view
    |> element("#gstr1-mark-filed")
    |> render_submit(%{"arn" => "R1-ARN"})

    assert render(view) =~ "Month closed."
    assert has_element?(view, "#month-strip", "Month closed — GSTR-1 and GSTR-3B filed.")
  end

  test "the operator (member) does not see the sign-off button and cannot sign", %{
    client: client,
    org: org
  } do
    member = user_fixture()
    {:ok, _} = Nila.Orgs.add_user(org, member.id, "member")
    conn = log_in_user(Phoenix.ConnTest.build_conn(), member)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}")

    refute has_element?(view, "#gst-signoff-button")

    render_click(view, "3b-sign-off", %{})
    assert render(view) =~ "permission"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"
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
