defmodule NilaWeb.Gst.UploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Storage

  @period "2025-10"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp submit(view, client) do
    view
    |> form("#gst-upload-form", intake: %{client_id: client.id, period: @period})
    |> render_submit()
  end

  # Uploads go straight from the browser to the bucket, so the server never sees
  # the bytes and nothing in the test process writes them either — LiveViewTest
  # simulates an entry's progress without running the JS uploader. The test
  # plays the browser: it takes the key the server presigned and writes the
  # content there before letting the entry finish, which is the state the world
  # is in by the time a real upload reports 100%.
  defp upload_file(view, name, content, type) do
    upload =
      file_input(view, "#gst-upload-form", :documents, [
        %{name: name, content: content, type: type}
      ])

    render_upload(upload, name, 0)
    ref = hd(upload.entries)["ref"]
    {:ok, _stored} = Storage.put(presigned_key(view, ref), content, content_type: type)

    assert render_upload(upload, name, 100) =~ name
    ref
  end

  defp presigned_key(view, ref) do
    :sys.get_state(view.pid).socket.assigns.entry_keys |> Map.fetch!(ref)
  end

  defp upload_pdf(view, name, kind) when kind in ~w(sales purchase) do
    ref = upload_file(view, name, "%PDF-1.4 fake bills", "application/pdf")

    view
    |> element("#gst-upload-#{kind}-#{ref}")
    |> render_click()

    ref
  end

  defp upload_json(view, name, content) do
    upload_file(view, name, content, "application/json")
  end

  test "mounts with one shared document drop", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    assert has_element?(view, "#gst-upload-page")
    assert has_element?(view, "#gst-upload-form")
    assert has_element?(view, "#gst-upload-documents")

    assert has_element?(
             view,
             "#gst-upload-documents input[type=file][accept='.pdf,.json'][multiple]"
           )

    refute has_element?(view, "#gst-upload-sales")
    refute has_element?(view, "#gst-upload-purchase")
    assert has_element?(view, "#gst-upload-submit")
  end

  test "prefills client and period from query params", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload?client_id=#{client.id}&period=2025-08")

    html = view |> element("#gst-upload-form") |> render()
    assert html =~ ~s(selected="" value="#{client.id}")
    assert html =~ ~s(selected="" value="2025-08")
  end

  # The trap this closes: a correct-looking default beside a file the form knows
  # nothing about. It cannot know the dates, but it can show that October is
  # empty and September is full — the tell in every wrong-month upload.
  test "each period says what that month already holds", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, _bills} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2025-09",
          kind: "purchase",
          status: "extracted",
          invoices: for(i <- 1..9, do: %{"invoice_number" => "S-#{i}"})
        }
      )

    {:ok, _snapshot} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: "2025-09", kind: "gstr2b", status: "extracted", invoices: [%{"inum" => "S-1"}]}
      )

    {:ok, view, _html} = live(conn, ~p"/gst/upload?client_id=#{client.id}")
    html = view |> element("#gst-upload-form") |> render()

    assert html =~ "Sep 2025 — 9 bills, 2B in"
    assert html =~ "Oct 2025 — nothing in yet"
  end

  test "with no client picked yet the periods stay bare", %{conn: conn, org: org, client: client} do
    {:ok, _bills} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2025-09",
          kind: "purchase",
          status: "extracted",
          invoices: [%{"invoice_number" => "S-1"}]
        }
      )

    {:ok, view, _html} = live(conn, ~p"/gst/upload")
    html = view |> element("#gst-upload-form") |> render()

    assert html =~ "Sep 2025"
    refute html =~ "Sep 2025 —"
  end

  test "shows an add-client empty state instead of an unusable form", %{
    conn: conn,
    client: client
  } do
    Nila.Repo.delete!(client)

    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    assert has_element?(view, "#gst-upload-empty", "No clients yet")
    assert has_element?(view, "#gst-upload-add-first-client", "Add your first client")
    refute has_element?(view, "#gst-upload-form")
  end

  test "another org's client id does not prefill", %{conn: conn} do
    %{org: other_org} = user_with_org_fixture(%{org: %{gstin: "27AAPFU0939F1ZV"}})

    {:ok, other_client} =
      Clients.create_client(%{org_id: other_org.id, name: "Rival Corp", type: "company"})

    {:ok, view, _html} = live(conn, ~p"/gst/upload?client_id=#{other_client.id}")

    html = view |> element("#gst-upload-form") |> render()
    refute html =~ ~s(selected="" value="#{other_client.id}")
  end

  test "one classified PDF creates one dump and one job", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)

    assert has_element?(view, "#gst-upload-progress")

    assert [dump] = Dumps.list(org.id, client.id, @period)
    assert dump.kind == "sales"
    assert dump.status == "received"
    assert Dumps.active(org.id, client.id, @period) == [dump]
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
  end

  test "a PDF needs an explicit Sales or Purchase choice", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref = upload_file(view, "bills.pdf", "%PDF-1.4 fake", "application/pdf")

    assert has_element?(view, "#gst-upload-sales-#{ref}")
    assert has_element?(view, "#gst-upload-purchase-#{ref}")

    submit(view, client)

    assert has_element?(view, "#gst-upload-error", "Choose Sales or Purchase for bills.pdf.")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "filed GSTR-1 JSON is identified without asking the operator", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref =
      upload_json(
        view,
        "filed-gstr1.json",
        ~s({"gstin":"33AAACS1234A1Z9","fp":"102025","b2b":[]})
      )

    assert has_element?(view, "#gst-upload-kind-#{ref}", "Filed GSTR-1")
    submit(view, client)

    assert [dump] = Dumps.list(org.id, client.id, @period)
    assert dump.kind == "filed_gstr1"
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
  end

  test "unrecognized JSON is explained and cannot be submitted", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref = upload_json(view, "random.json", ~s({"something":"else"}))

    assert has_element?(
             view,
             "#gst-upload-kind-#{ref}",
             "This is not a recognized GST portal file"
           )

    submit(view, client)

    assert has_element?(view, "#gst-upload-error", "not a GSTR-2B or filed GSTR-1 portal file")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "ambiguous portal JSON is refused instead of silently routed", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref =
      upload_json(
        view,
        "ambiguous.json",
        ~s({"gstin":"33AAACS1234A1Z9","fp":"102025","b2b":[],"docdata":{}})
      )

    assert has_element?(view, "#gst-upload-kind-#{ref}", "matches more than one portal format")
    submit(view, client)

    assert has_element?(view, "#gst-upload-error", "matches more than one portal format")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "a mixed drop creates a dump per file", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "bills.pdf", "purchase")
    json_ref = upload_json(view, "gstr2b.json", ~s({"docdata":{"b2b":[]}}))

    assert has_element?(view, "#gst-upload-kind-#{json_ref}", "GSTR-2B")
    submit(view, client)

    kinds = org.id |> Dumps.list(client.id, @period) |> Enum.map(& &1.kind) |> Enum.sort()
    assert kinds == ["gstr2b", "purchase"]

    for dump <- Dumps.list(org.id, client.id, @period) do
      assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})
    end
  end

  # The file reaches the bucket the moment it is dropped, so removing the row
  # has to take the object with it. Nothing downstream would: the dump row that
  # points at it is never written.
  test "removing a file takes its object out of storage", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref = upload_pdf(view, "bills.pdf", "purchase")
    key = presigned_key(view, ref)
    assert {:ok, "%PDF-1.4 fake bills"} = Storage.get(key)

    view
    |> element(~s(#gst-upload-documents button[aria-label="Remove bills.pdf"]))
    |> render_click()

    assert {:error, _reason} = Storage.get(key)
    refute has_element?(view, "#gst-upload-documents-entry-#{ref}")
  end

  # The read-back is new surface: the browser reports a file uploaded that the
  # server then cannot fetch. Reporting that as an unrecognized portal file
  # would send the operator to check a download that was never the problem.
  test "a portal file that cannot be read back says so rather than blaming it", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload =
      file_input(view, "#gst-upload-form", :documents, [
        %{name: "gstr2b.json", content: ~s({"docdata":{"b2b":[]}}), type: "application/json"}
      ])

    # Nothing stands in for the browser here, so the object is never written —
    # the state a dropped upload leaves behind.
    render_upload(upload, "gstr2b.json", 100)
    ref = hd(upload.entries)["ref"]

    assert has_element?(view, "#gst-upload-kind-#{ref}", "could not read this back")

    submit(view, client)

    assert has_element?(view, "#gst-upload-error", "could not read gstr2b.json back")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "rejects a submit with no files attached", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    submit(view, client)

    assert has_element?(view, "#gst-upload-error")
    assert Dumps.list(org.id, client.id, @period) == []
    refute_enqueued(worker: DumpWorker)
  end

  test "progress narrates per dump and offers the month when done", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)

    [dump] = Dumps.list(org.id, client.id, @period)

    assert has_element?(view, "#gst-dump-#{dump.id}")
    assert render(view) =~ "Queued"

    # The worker runs and broadcasts; drive it inline and let the view catch up.
    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    assert render(view) =~ "Done"
    assert Dumps.active(org.id, client.id, @period) == []
    assert has_element?(view, "#gst-upload-open-month[autofocus]")

    view |> element("#gst-upload-open-month") |> render_click()
    assert_redirect(view, "/gst/#{client.id}/#{@period}")
  end

  test "extraction narrates in pages read, not a dead spinner", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "bills.pdf", "purchase")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    # The client-month the pile belongs to stays on screen through the wait.
    assert has_element?(view, "#gst-upload-progress-header", "Breeze Tech")
    assert has_element?(view, "#gst-upload-progress-header", "Oct 2025")

    plan = %{done: 0, total: 8, pages_done: 0, page_count: 57}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, plan}}
    )

    # Nothing has landed: the size of the job, and an indeterminate bar.
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "57 pages to read")
    refute has_element?(view, "#gst-dump-progress-#{dump.id} progress[value]")

    landed = %{done: 3, total: 8, pages_done: 20, page_count: 57}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, landed}}
    )

    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "20 of 57 pages read")
    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='20'][max='57']")

    # A resent window holds the bar still for another ~40s round-trip; saying so
    # is what separates a slow read from a screen that looks hung.
    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting_retry, "7-14"}}
    )

    assert has_element?(
             view,
             "#gst-dump-progress-#{dump.id}",
             "Pages 7-14 did not come back. Asking again."
           )

    # Derivation is a different unit of work — a bar frozen at 20/57 would read
    # as stuck, so it goes away rather than lying.
    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "purchase", :reconciling})

    assert render(view) =~ "Reconciling against 2B"
    refute has_element?(view, "#gst-dump-progress-#{dump.id}")
  end

  test "a worker retry keeps the last progress visible and explains the restart", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "bills.pdf", "purchase")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    landed = %{done: 8, total: 14, pages_done: 8, page_count: 14}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, landed}}
    )

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:worker_retrying, 2, 3}}
    )

    assert has_element?(
             view,
             "#gst-dump-#{dump.id}",
             "Processing interrupted — retrying (2 of 3)"
           )

    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "8 of 14 pages read")
    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='8'][max='14']")

    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "purchase", :extracting})

    assert has_element?(view, "#gst-dump-#{dump.id}", "Reading again — attempt 2 of 3")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "8 of 14 pages read")

    restarted = %{done: 0, total: 14, pages_done: 0, page_count: 14}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, restarted}}
    )

    assert has_element?(view, "#gst-dump-#{dump.id}", "Reading again — attempt 2 of 3")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "14 pages to read")
    refute has_element?(view, "#gst-dump-progress-#{dump.id} progress[value]")
  end

  test "a read that lost pages names them instead of reporting a clean finish", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "sales",
       {:done, client.id, @period, [1, 2]}}
    )

    assert render(view) =~ "Read, but not all of it"
    assert render(view) =~ "Pages 1, 2 produced no bill"
    refute has_element?(view, "#gst-dump-#{dump.id} .text-success")

    # The month is still derived from what did land, so the way in stays open.
    assert has_element?(view, "#gst-upload-open-month")
  end

  test "a held dump links to the signed month", %{conn: conn, org: org, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "sales", :held})

    assert render(view) =~ "this month&#39;s return is already signed"

    assert has_element?(
             view,
             "#gst-dump-open-month-#{dump.id}[href='/gst/#{client.id}/#{@period}']"
           )
  end

  test "a dump after filing points intake at the open month", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "sales", :after_filing})

    open_period = Calendar.closeable_period(Date.utc_today())

    assert render(view) =~
             "This month is already filed — bring this into the current month instead"

    assert has_element?(
             view,
             "#gst-dump-open-period-#{dump.id}[href='/gst/upload?client_id=#{client.id}&period=#{open_period}']",
             "Bring it into the open month →"
           )

    refute has_element?(view, "#gst-dump-#{dump.id} .loading")
    refute render(view) =~ "reopen"
  end

  test "a failed dump can return to the same prefilled form", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    upload_pdf(view, "sales.pdf", "sales")
    submit(view, client)
    [dump] = Dumps.list(org.id, client.id, @period)

    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "sales", {:failed, "bad"}})
    view |> element("#gst-dump-try-again-#{dump.id}") |> render_click()

    html = view |> element("#gst-upload-form") |> render()
    assert html =~ ~s(selected="" value="#{client.id}")
    assert html =~ ~s(selected="" value="#{@period}")
  end
end
