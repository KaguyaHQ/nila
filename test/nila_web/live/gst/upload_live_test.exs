defmodule NilaWeb.Gst.UploadLiveTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Phoenix.LiveViewTest

  alias Nila.Clients
  alias Nila.Gst.Filing.Calendar
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Sales.Gstr1
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

  test "sales bills accepts a client without requiring Tally", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sales-bills")

    assert has_element?(view, "#sales-bills-page", "Sales")
    assert has_element?(view, "#sales-bills-page", "Bring in sales invoices")

    assert has_element?(
             view,
             "#sales-bills-page",
             "sales working for Breeze Tech"
           )

    assert has_element?(view, "#sales-bills-form")
    assert has_element?(view, "#sales-bills-submit", "Add to")
    refute has_element?(view, "#sales-bills-page", "Tally")
    refute has_element?(view, "#sales-bills-form label", "Client")
    refute has_element?(view, "#sales-bills-form select[name='intake[client_id]']")
    refute has_element?(view, "#sales-bills-connect-tally")
    assert has_element?(view, "#app-shell nav", "Firm")
  end

  test "sales bills starts processing without a Tally connection", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/sales-bills")

    upload =
      file_input(view, "#sales-bills-form", :documents, [
        %{name: "sales.pdf", content: "%PDF-1.4 fake bills", type: "application/pdf"}
      ])

    render_upload(upload, "sales.pdf", 0)
    ref = hd(upload.entries)["ref"]
    {:ok, _stored} = Storage.put(presigned_key(view, ref), "%PDF-1.4 fake bills")
    render_upload(upload, "sales.pdf", 100)

    view
    |> form("#sales-bills-form", intake: %{})
    |> render_submit()

    period = Calendar.closeable_period(Date.utc_today())

    assert [%{kind: "sales", client_id: client_id, sales_batch_id: batch_id}] =
             Dumps.list(org.id, client.id, period)

    assert client_id == client.id
    assert is_integer(batch_id)

    assert %Nila.Gst.Sales.Batch{client_id: ^client_id, tally_company_id: nil} =
             Nila.Repo.get!(Nila.Gst.Sales.Batch, batch_id)

    [dump] = Dumps.list(org.id, client.id, period)

    assert_redirect(
      view,
      ~p"/sales-bills/#{client.id}/batch/#{Nila.Gst.Sales.TallyPacket.ref([dump])}"
    )
  end

  test "sales bills ignores a submitted client and uses the active workspace", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, other_client} =
      Clients.create_client(%{org_id: org.id, name: "Caltech", type: "company"})

    period = Calendar.closeable_period(Date.utc_today())

    {:ok, view, _html} =
      live(conn, ~p"/gst/upload?client_id=#{client.id}&period=#{period}&kind=sales")

    upload =
      file_input(view, "#sales-bills-form", :documents, [
        %{name: "sales.pdf", content: "%PDF-1.4 fake bills", type: "application/pdf"}
      ])

    render_upload(upload, "sales.pdf", 0)
    ref = hd(upload.entries)["ref"]
    {:ok, _stored} = Storage.put(presigned_key(view, ref), "%PDF-1.4 fake bills")
    render_upload(upload, "sales.pdf", 100)

    render_submit(view, "submit", %{"intake" => %{"client_id" => other_client.id}})

    assert [%{client_id: active_id}] = Dumps.list(org.id, client.id, period)
    assert active_id == client.id
    assert Dumps.list(org.id, other_client.id, period) == []
  end

  test "sales bills becomes a batch workspace after the first import", %{
    conn: conn,
    org: org,
    client: client
  } do
    invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "29",
          "invoice_number" => "INV-104",
          "invoice_date" => "04.11.2025",
          "seller" => %{"gstin" => "33AEWPH4158J1Z3"},
          "buyer" => %{
            "name" => "Siemens Healthcare",
            "gstin" => "29AAVCS8021P1ZB"
          },
          "line_items" => [
            %{
              "description" => "Service",
              "hsn_sac" => "998719",
              "taxable_value" => 8_500,
              "igst_rate" => 18,
              "igst_amount" => 1_530
            }
          ],
          "printed_grand_total" => 10_030
        }
      })
      |> Map.put("id", "d104_inv_001")

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2025-11",
          kind: "sales",
          status: "extracted",
          invoices: [invoice],
          meta: %{"sales_batch" => true, "original_name" => "november.pdf"}
        }
      )

    {:ok, view, _html} = live(conn, ~p"/sales-bills")

    assert has_element?(view, "#sales-bills-page", "Sales bills")
    period = Calendar.closeable_period(Date.utc_today())

    assert has_element?(
             view,
             "#sales-bills-bring-invoices[href='/gst/upload?client_id=#{client.id}&period=#{period}&kind=sales']"
           )

    refute has_element?(view, "#sales-bills-importer")
    refute has_element?(view, "#sales-bills-form")

    assert has_element?(view, "#sales-batches", "Batches")
    assert has_element?(view, "#sales-batches-table", "Breeze Tech")
    assert has_element?(view, "#sales-batches-table", "1 invoice")
    assert has_element?(view, "#sales-batches-table", "1 ready")
    refute has_element?(view, "#sales-batches-table", "INV-104")
    refute has_element?(view, "#sales-batches-table", "Siemens Healthcare")
    refute has_element?(view, "#sales-batches-table", "₹10,030.00")

    assert has_element?(
             view,
             "#sales-import-#{dump.id} a[href='/sales-bills/#{client.id}/batch/#{dump.id}']"
           )
  end

  test "partial sales bill validation events do not crash the importer", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} =
      live(conn, ~p"/gst/upload?client_id=#{client.id}&period=#{@period}&kind=sales")

    upload_html = render_change(view, "validate", %{"_target" => ["documents"]})
    partial_html = render_change(view, "validate", %{})

    assert upload_html =~ "Bring in sales invoices"
    assert partial_html =~ "Bring in sales invoices"
    assert has_element?(view, "#sales-bills-form")
  end

  test "sales bills shows the same add-client empty state as Banking", %{
    conn: conn,
    client: client
  } do
    Nila.Repo.delete!(client)

    {:ok, view, _html} = live(conn, ~p"/sales-bills")

    assert has_element?(view, "#sales-bills-empty", "No clients yet")
    assert has_element?(view, "#sales-bills-add-first-client", "Add your first client")
    refute has_element?(view, "#sales-bills-form")
  end

  test "mounts with one shared document drop", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    assert has_element?(view, "#gst-upload-page")
    assert has_element?(view, "#gst-upload-form")
    assert has_element?(view, "#gst-upload-documents")

    assert has_element?(
             view,
             "#gst-upload-documents input[type=file][accept='.pdf,.jpg,.jpeg,.png,.webp,.json'][multiple]"
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

  test "a sales-period launch uses the shared uploader in locked sales context", %{
    conn: conn,
    client: client
  } do
    {:ok, view, _html} =
      live(conn, ~p"/gst/upload?client_id=#{client.id}&period=2025-08&kind=sales")

    assert has_element?(view, "#sales-bills-page", "Bring in sales invoices")
    assert has_element?(view, "#sales-bills-page", "Aug 2025 sales working for Breeze Tech")
    assert has_element?(view, "#sales-bills-submit", "Add to Aug 2025 sales")

    assert has_element?(
             view,
             "#sales-bills-documents input[type=file][accept='.pdf,.jpg,.jpeg,.png,.webp'][multiple]"
           )

    refute has_element?(view, "#gst-upload-page")
    refute has_element?(view, "select[name='intake[client_id]']")
    refute has_element?(view, "select[name='intake[period]']")
    refute has_element?(view, "#sales-bills-page", "Tally")
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

  test "the active client is preselected with its period context", %{
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
          invoices: [%{"invoice_number" => "S-1"}]
        }
      )

    {:ok, view, _html} = live(conn, ~p"/gst/upload")
    html = view |> element("#gst-upload-form") |> render()

    assert html =~ ~s(<option selected="" value="#{client.id}">)
    assert html =~ "Sep 2025 — 1 bill"
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

  test "an invoice image can be classified and queued like a PDF", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/upload")

    ref = upload_file(view, "invoice.jpg", <<0xFF, 0xD8, 0xFF, 0xD9>>, "image/jpeg")
    assert has_element?(view, "#gst-upload-sales-#{ref}")
    assert has_element?(view, "#gst-upload-purchase-#{ref}")

    view
    |> element("#gst-upload-purchase-#{ref}")
    |> render_click()

    submit(view, client)

    assert [dump] = Dumps.list(org.id, client.id, @period)
    assert dump.kind == "purchase"
    assert [key] = dump.file_keys
    assert String.ends_with?(key, "/original.jpg")
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
    assert_redirect(view, "/gst/#{client.id}/#{@period}/sales")
  end

  test "extraction presents one preparation phase followed by bill progress", %{
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

    transcribing = %{stage: :transcribing, done: 0, total: 1}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, transcribing}}
    )

    assert has_element?(view, "#gst-dump-#{dump.id}", "Preparing the document")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "reading the scan")
    refute has_element?(view, "#gst-dump-progress-#{dump.id} progress")

    # Page labelling is internal preparation, not a first run through the bills.
    # The row spinner remains the only animation instead of a first progress bar
    # counting 1..57 and then starting over.
    segmenting = %{stage: :segmenting, done: 20, total: 57, pages_done: 20, page_count: 57}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, segmenting}}
    )

    assert has_element?(view, "#gst-dump-#{dump.id}", "Preparing the document")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "57 pages received")
    refute has_element?(view, "#gst-dump-progress-#{dump.id} progress")

    # Once bills are known, zero is determinate. There is no second loader.
    reading = %{stage: :reading, done: 0, total: 8}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, reading}}
    )

    assert has_element?(view, "#gst-dump-#{dump.id}", "Reading the bills")

    assert has_element?(
             view,
             "#gst-dump-progress-#{dump.id}",
             "8 bills found — starting to read"
           )

    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='0'][max='8']")

    landed = %{stage: :reading, done: 3, total: 8}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, landed}}
    )

    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "3 of 8 bills read")
    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='3'][max='8']")

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

    finished = %{stage: :reading, done: 8, total: 8}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, finished}}
    )

    # Final bookkeeping keeps the completed bar instead of flashing a loader.
    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "purchase", :reconciling})

    assert has_element?(view, "#gst-dump-#{dump.id}", "Checking the result")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "8 of 8 bills read")
    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='8'][max='8']")
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

    landed = %{stage: :reading, done: 8, total: 14}

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

    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "8 of 14 bills read")
    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='8'][max='14']")

    send(view.pid, {:gst_dump_progress, dump.id, client.id, @period, "purchase", :extracting})

    assert has_element?(view, "#gst-dump-#{dump.id}", "Reading again — attempt 2 of 3")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "8 of 14 bills read")

    restarted = %{stage: :transcribing, done: 0, total: 1}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, restarted}}
    )

    assert has_element?(view, "#gst-dump-#{dump.id}", "Reading again — attempt 2 of 3")
    assert has_element?(view, "#gst-dump-progress-#{dump.id}", "reading the scan")
    refute has_element?(view, "#gst-dump-progress-#{dump.id} progress")

    bills_found = %{stage: :reading, done: 0, total: 14}

    send(
      view.pid,
      {:gst_dump_progress, dump.id, client.id, @period, "purchase", {:extracting, bills_found}}
    )

    assert has_element?(
             view,
             "#gst-dump-progress-#{dump.id}",
             "14 bills found — starting to read"
           )

    assert has_element?(view, "#gst-dump-progress-#{dump.id} progress[value='0'][max='14']")
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
             "#gst-dump-open-month-#{dump.id}[href='/gst/#{client.id}/#{@period}/sales/uploads']"
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
