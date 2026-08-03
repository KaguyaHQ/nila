defmodule NilaWeb.Gst.ExceptionsLiveTest do
  use NilaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Purchase.Reconciliation, as: Recon

  @period "2025-10"
  @gstin "33AAACS1234A1Z9"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin
      })

    books = %{
      "id" => "page_01",
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => @gstin,
      "invoice_number" => "1134",
      "invoice_date" => ~D[2025-10-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "images" => [],
      "pages" => [1]
    }

    g2b = %{
      "vendor_gstin" => @gstin,
      "vendor_name" => "SHARMA STEELS",
      "invoice_number" => "CHN-SER-1134",
      "invoice_date" => ~D[2025-10-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "pos" => "33"
    }

    recon = Recon.reconcile([books], [g2b])
    rows = Register.rows([books], recon, %{})

    gstr2b_arrived!(org, client, @period, [g2b])

    {:ok, _month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  defp books(attrs) do
    Map.merge(
      %{
        "id" => "books_01",
        "vendor_name" => "Sharma Steels",
        "vendor_gstin" => @gstin,
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-10-05],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "images" => [],
        "pages" => [1]
      },
      attrs
    )
  end

  defp g2b(attrs) do
    Map.merge(
      %{
        "vendor_gstin" => @gstin,
        "vendor_name" => "SHARMA STEELS",
        "invoice_number" => "INV-001",
        "invoice_date" => ~D[2025-10-05],
        "taxable_paise" => 1_000_000,
        "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
        "total_paise" => 1_180_000,
        "pos" => "33"
      },
      attrs
    )
  end

  # Every exception in this file is a real disagreement with the portal, which
  # only exists once the portal snapshot is in. `reconcile(books, [])` here
  # models "the 2B arrived and this bill is not in it", not "no 2B yet".
  defp put_recon!(org, client, period, books, recon) do
    gstr2b_arrived!(org, client, period)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    month
  end

  # A disputed bill (books number vs 2B number) that also carries page images —
  # the shape the evidence viewer exists for.
  defp disputed_with_images!(org, client, period, images) do
    books = books(%{"id" => "img_01", "invoice_number" => "1134", "images" => images})
    g2b = g2b(%{"invoice_number" => "CHN-SER-1134"})
    recon = Recon.reconcile([books], [g2b])
    put_recon!(org, client, period, [books], recon)
  end

  defp evidence_url(client, period, basename),
    do: "/gst/#{client.id}/#{period}/evidence/#{basename}"

  defp at(html, needle) do
    {index, _length} = :binary.match(html, needle)
    index
  end

  test "the bill sits after the disputed grid and before the verbs", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-05"
    disputed_with_images!(org, client, period, ["d1_page_01.webp"])

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")
    html = render(view)

    assert has_element?(view, "#gst-exception-evidence")
    assert has_element?(view, ~s|#gst-exception-evidence-frame-open|)

    assert has_element?(
             view,
             ~s|#gst-exception-evidence img[src="#{evidence_url(client, period, "d1_page_01.webp")}"]|
           )

    # The dispute is the hero: the ✓/✗ grid leads, the bill corroborates it,
    # and the decision row stays below both.
    assert at(html, ~s|id="gst-exception-candidates"|) <
             at(html, ~s|id="gst-exception-evidence"|)

    assert at(html, ~s|id="gst-exception-evidence"|) < at(html, "Confirm — same bill")

    # Read-only: no resolution verb inside the evidence block.
    refute has_element?(view, "#gst-exception-evidence button[phx-click='confirm_pair']")
  end

  test "an absence exception renders no image block and no placeholder", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-06"
    gstr2b = g2b(%{"vendor_name" => "PORTAL VENDOR", "invoice_number" => "PORTAL-9"})
    put_recon!(org, client, period, [], Recon.reconcile([], [gstr2b]))

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-exception-gstr2b")
    refute has_element?(view, "#gst-exception-evidence")
    refute has_element?(view, "#gst-exception-evidence-unavailable")
    refute render(view) =~ "Scanned bill"
  end

  describe "the s.16(2)(a) attestation" do
    test "unsubstantiated credit is claimed, named, and asked about", %{
      conn: conn,
      org: org,
      client: client
    } do
      period = "2026-07"
      gstr2b = g2b(%{"vendor_name" => "PORTAL VENDOR", "invoice_number" => "P-1"})
      put_recon!(org, client, period, [], Recon.reconcile([], [gstr2b]))

      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

      # The bridge shows the money inside the claim rather than deducted from
      # it: a bill that hasn't reached us says nothing about what the client
      # holds.
      assert has_element?(view, "#gst-itc-bridge-reported", "Reported in GSTR-2B")
      assert has_element?(view, "#gst-itc-bridge-claimable", "Claimable ITC")

      assert has_element?(
               view,
               "#gst-itc-bridge-awaiting-document",
               "client hasn't sent us the bill"
             )

      assert has_element?(view, "#gst-itc-attestation", "Confirm the client holds tax invoices")
      assert has_element?(view, "#gst-attest-held")
      assert has_element?(view, "#gst-attest-not-held")
      assert has_element?(view, "#gst-attest-unknown")
    end

    test "confirming possession keeps the credit and records who said so", %{
      conn: conn,
      org: org,
      client: client
    } do
      period = "2026-08"
      gstr2b = g2b(%{"invoice_number" => "P-2", "total_paise" => 2_360_000})
      put_recon!(org, client, period, [], Recon.reconcile([], [gstr2b]))

      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

      claimed_before = view |> element("#gst-itc-bridge-claimable") |> render()

      view |> element("#gst-attest-held") |> render_click()

      assert has_element?(view, "#gst-itc-attestation", "Client holds the tax invoices")
      assert view |> element("#gst-itc-bridge-claimable") |> render() == claimed_before

      # Answered, so it is no longer the open question withholding the month.
      refute has_element?(view, "#gst-attest-held")
      assert has_element?(view, "#gst-attest-undo")
    end

    test "'not held' withholds the credit for the right reason", %{
      conn: conn,
      org: org,
      client: client
    } do
      period = "2026-09"
      gstr2b = g2b(%{"invoice_number" => "P-3"})
      put_recon!(org, client, period, [], Recon.reconcile([], [gstr2b]))

      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

      view |> element("#gst-attest-not-held") |> render_click()

      assert has_element?(view, "#gst-itc-attestation", "withheld from the claim")

      # It leaves the claim as its own term, not folded into blocked credits:
      # a substantiation failure is not an ineligible credit.
      refute has_element?(view, "#gst-itc-bridge-awaiting-document")
      assert has_element?(view, "#gst-itc-bridge-claimable", "₹0")
    end

    test "'unknown' is a real answer that says the month is not settled", %{
      conn: conn,
      org: org,
      client: client
    } do
      period = "2026-10"
      gstr2b = g2b(%{"invoice_number" => "P-4"})
      put_recon!(org, client, period, [], Recon.reconcile([], [gstr2b]))

      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

      view |> element("#gst-attest-unknown") |> render_click()

      # Nobody is forced to assert "no" to proceed. The signature gate itself is
      # asserted in the signoffs test, where the scope lives.
      assert has_element?(view, "#gst-itc-attestation", "cannot be signed until this is settled")
      assert has_element?(view, "#gst-attest-undo")
    end

    test "no unsubstantiated supply means no question to ask", %{
      conn: conn,
      org: org,
      client: client
    } do
      period = "2026-12"
      books = books(%{"id" => "m1", "invoice_number" => "M-1"})
      gstr2b = g2b(%{"invoice_number" => "M-1"})
      put_recon!(org, client, period, [books], Recon.reconcile([books], [gstr2b]))

      {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

      refute has_element?(view, "#gst-itc-attestation")
      refute has_element?(view, "#gst-itc-bridge-awaiting-document")
    end
  end

  test "a bill with nothing to compare against still shows the scan above its verbs", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-11"

    books =
      books(%{"id" => "solo_01", "invoice_number" => "BOOK-ONLY", "images" => ["d1_p1.webp"]})

    put_recon!(org, client, period, [books], Recon.reconcile([books], []))

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")
    html = render(view)

    refute has_element?(view, "#gst-exception-candidates")
    assert has_element?(view, "#gst-exception-evidence")
    assert at(html, ~s|id="gst-exception-evidence"|) < at(html, ~s|id="gst-accept-await-2b"|)
  end

  test "clicking the bill opens the reader and Esc returns with the same exception selected", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-07"
    disputed_with_images!(org, client, period, ["d1_page_01.webp"])

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")
    refute has_element?(view, "#gst-evidence-overlay")

    view |> element("#gst-exception-evidence-frame-open") |> render_click()
    assert has_element?(view, "#gst-evidence-overlay")

    assert has_element?(
             view,
             ~s|#gst-evidence-overlay img[src="#{evidence_url(client, period, "d1_page_01.webp")}"]|
           )

    # The dim area around the bill dismisses too — the hook reads the event off
    # the stage, so if this attribute goes missing the backdrop silently stops
    # closing and the only way out is the ✕.
    assert has_element?(
             view,
             ~s|#gst-evidence-overlay-stage[data-close-event="close-evidence"]|
           )

    view |> element("#gst-evidence-overlay") |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#gst-evidence-overlay")
    assert has_element?(view, "#queue-img_01.bg-base-200")
    assert has_element?(view, "#gst-exception-detail", "1134")
    assert has_element?(view, "#gst-exception-evidence")
  end

  test "a multi-page bill pages forward and back", %{conn: conn, org: org, client: client} do
    period = "2026-08"
    disputed_with_images!(org, client, period, ["d1_page_01.webp", "d1_page_02.webp"])

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-exception-evidence-frame-nav", "1/2")
    view |> element("#gst-exception-evidence-frame-nav-next") |> render_click()

    assert has_element?(view, "#gst-exception-evidence-frame-nav", "2/2")

    assert has_element?(
             view,
             ~s|#gst-exception-evidence img[src="#{evidence_url(client, period, "d1_page_02.webp")}"]|
           )

    # The reader opens on the page being previewed, and its own arrows work.
    view |> element("#gst-exception-evidence-frame-open") |> render_click()
    assert has_element?(view, "#gst-evidence-overlay-nav", "2/2")
    view |> element("#gst-evidence-overlay-nav-prev") |> render_click()
    assert has_element?(view, "#gst-evidence-overlay-nav", "1/2")

    assert has_element?(
             view,
             ~s|#gst-evidence-overlay img[src="#{evidence_url(client, period, "d1_page_01.webp")}"]|
           )
  end

  test "a bill whose pages could not be rendered says so and offers the original", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-09"

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: period,
          kind: "purchase",
          status: "extracted",
          file_keys: ["dumps/#{org.id}/#{client.id}/#{period}/oct-bills.pdf"],
          meta: %{"evidence_unavailable" => true}
        }
      )

    books = books(%{"id" => "d#{dump.id}_page_01", "invoice_number" => "1134", "images" => []})
    recon = Recon.reconcile([books], [g2b(%{"invoice_number" => "CHN-SER-1134"})])
    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-exception-evidence-unavailable", "couldn't be rendered")
    assert has_element?(view, "#gst-exception-evidence-unavailable", "oct-bills.pdf")
    refute has_element?(view, "#gst-exception-evidence")

    assert has_element?(
             view,
             ~s|#gst-exception-evidence-unavailable a[href="/gst/#{client.id}/#{period}/original/#{dump.id}/0"]|
           )
  end

  test "a bill that was never received shows no rendering-failure notice", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-10"
    books = books(%{"id" => "plain_01", "invoice_number" => "1134", "images" => []})
    recon = Recon.reconcile([books], [g2b(%{"invoice_number" => "CHN-SER-1134"})])
    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    refute has_element?(view, "#gst-exception-evidence")
    refute has_element?(view, "#gst-exception-evidence-unavailable")
  end

  test "a signed-off month hides the verbs and rejects resolutions server-side", %{
    conn: conn,
    user: user,
    org: org,
    client: client
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    scope = Nila.Accounts.Scope.for_user(user)
    confirm_sales_complete!(org, client, @period)

    # Settle the register the way a reviewer would: the month holds one pair
    # whose invoice numbers differ, and a signature is refused while any row is
    # unsettled.
    ref =
      month.recon
      |> get_in(["needs_human", Access.at(0), "candidates"])
      |> hd()
      |> Recon.gstr2b_ref()

    {:ok, _} =
      Resolutions.record_and_refresh(
        month,
        %{"verb" => "confirm_pair", "books_id" => "page_01", "gstr2b_ref" => ref},
        user.id
      )

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    {:ok, _} = Signoffs.sign_off(month, scope)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    refute has_element?(view, "button", "Confirm — same bill")

    for {event, params} <- [
          {"confirm_pair", %{"id" => "page_01"}},
          {"reject_all", %{"id" => "page_01"}},
          {"accept_unmatched", %{"id" => "page_01", "reason" => "await_2b"}},
          {"dismiss_2b", %{"id" => "page_01"}}
        ] do
      render_click(view, event, params)
      assert render(view) =~ "Month is signed off"
    end

    # Only the decision that settled the register before signing; the rejected
    # verbs above wrote nothing.
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert Enum.map(Resolutions.list(month.id), & &1.verb) == ["confirm_pair"]
  end

  test "renders the queue and the side-by-side diff", %{conn: conn, client: client} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    assert has_element?(view, "#gst-exception-queue")
    assert has_element?(view, "#queue-page_01")
    assert has_element?(view, "#queue-page_01 .truncate")
    assert has_element?(view, "#gst-exception-detail")
    assert render(view) =~ "1134"
    assert render(view) =~ "CHN-SER-1134"
  end

  test "opening exceptions derives assigns without writing the projection or resolutions", %{
    conn: conn,
    org: org,
    client: client
  } do
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    {:ok, before} =
      ClientMonths.upsert(%{
        org_id: month.org_id,
        client_id: month.client_id,
        period: month.period,
        state: month.state,
        register_rows: [%{"stored" => "projection"}],
        recon: month.recon,
        summary: %{"stored" => "summary"}
      })

    assert {:ok, _view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    {:ok, after_open} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert after_open.register_rows == before.register_rows
    assert after_open.summary == before.summary
    assert after_open.updated_at == before.updated_at
    assert Resolutions.list(month.id) == []
  end

  test "confirm marks the exception resolved in place with its outcome", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view
    |> element("button", "Confirm — same bill")
    |> render_click()

    # Stays visible (not vanished), marked done, register updated, all-cleared banner shown.
    assert has_element?(view, "#queue-page_01")
    assert render(view) =~ "Confirmed — same bill"
    assert has_element?(view, "#gst-exceptions-cleared")
    assert has_element?(view, "#gst-exceptions-progress")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    assert [res] = Resolutions.list(month.id)
    assert res.verb == "confirm_pair"
    assert res.books_id == "page_01"

    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "human_confirmed" in row["match_basis"]
  end

  test "undo reopens a resolved exception", %{conn: conn, client: client, org: org} do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view |> element("button", "Confirm — same bill") |> render_click()
    assert render(view) =~ "Confirmed — same bill"

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()

    # Back to open: the verb buttons return, the register match is gone.
    assert has_element?(view, "button", "Confirm — same bill")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    workings = Resolutions.workings(month)
    assert workings.recon["matched"] == []
    assert length(workings.recon["needs_human"]) == 1
  end

  test "correcting the invoice number auto-matches via the engine", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{@period}/exceptions")

    view |> element("button", "Correct the number") |> render_click()

    view
    |> form("#gst-exception-detail form", %{value: "CHN-SER-1134"})
    |> render_submit()

    assert render(view) =~ "Corrected"
    assert has_element?(view, "#gst-exception-outcome")

    month = ClientMonths.get_by_period(org.id, client.id, @period) |> elem(1)
    workings = Resolutions.workings(month)
    assert [row] = workings.recon["matched"]
    assert "invoice_number" in row["match_basis"]
  end

  test "a fuzzy-name single-candidate exception is also resolvable (not just invoice_number_mismatch)",
       %{
         conn: conn,
         org: org,
         client: client
       } do
    # No valid vendor GSTIN + a fuzzy name + exact value -> fuzzy_name_weak
    # corroboration with one candidate: must be resolvable, same as Bikezone.
    books = %{
      "id" => "fz_01",
      "vendor_name" => "Maheswari & Co",
      "vendor_gstin" => nil,
      "invoice_number" => "1",
      "invoice_date" => ~D[2025-11-05],
      "taxable_paise" => 238_100,
      "tax_paise" => %{"cgst" => 24_400, "sgst" => 24_400, "igst" => 0},
      "total_paise" => 286_900,
      "images" => [],
      "pages" => [1]
    }

    g2b = %{
      "vendor_gstin" => "33APZPP6215J1ZB",
      "vendor_name" => "MAHESWARI AND CO",
      "invoice_number" => "125",
      "invoice_date" => ~D[2025-11-05],
      "taxable_paise" => 238_100,
      "tax_paise" => %{"cgst" => 24_400, "sgst" => 24_400, "igst" => 0},
      "total_paise" => 286_900,
      "pos" => "33"
    }

    recon = Recon.reconcile([books], [g2b])
    assert [%{"reason" => %{"code" => "fuzzy_name_weak_corroboration"}}] = recon["needs_human"]
    rows = Register.rows([books], recon, %{})

    {:ok, _} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-12",
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-12/exceptions")
    assert has_element?(view, "button", "Confirm — same bill")
  end

  test "ambiguous candidates can be chosen or all rejected into unmatched verbs", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-01"
    books = books(%{"id" => "ambiguous_01", "invoice_number" => "DUP-1"})
    first = g2b(%{"invoice_number" => "DUP-1", "total_paise" => 1_180_000})
    second = g2b(%{"invoice_number" => "DUP-1", "total_paise" => 1_180_100})
    recon = Recon.reconcile([books], [first, second])
    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-candidate-1")
    assert has_element?(view, "#gst-candidate-2")
    refute render(view) =~ "isn&#39;t wired"

    view |> element("#gst-candidate-2 button", "This one") |> render_click()
    assert render(view) =~ "Matched to the chosen 2B row"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, period)
    assert [chosen] = Resolutions.list(month.id)
    assert chosen.gstr2b_ref == Recon.gstr2b_ref(second)

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    view |> element("#gst-reject-all-candidates", "None of these") |> render_click()

    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "#gst-accept-not-claimable")

    assert Enum.count(Resolutions.list(month.id), &(&1.verb == "reject_pair")) == 2
  end

  test "accepting an unmatched bill removes it from decision counts and ITC", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-02"
    books = books(%{"id" => "unmatched_01", "invoice_number" => "BOOK-ONLY"})
    recon = Recon.reconcile([books], [])
    put_recon!(org, client, period, [books], recon)

    {:ok, month_view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")
    assert has_element?(month_view, "#month-door-decisions", "Work the decision")

    {:ok, today, _html} = live(conn, ~p"/today")
    assert has_element?(today, "#today-row-#{client.id}-#{period}", "1 to decide")

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")
    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "button", "Correct the number")
    refute render(view) =~ "isn&#39;t wired"

    # Two buttons that move the same zero rupees read as a trick question. The
    # page has to say that the claim is untouched either way, and that the
    # whole difference is the follow-up each one records.
    assert has_element?(view, "#gst-accept-unmatched-note", "Neither changes this month")
    assert has_element?(view, "#gst-accept-await-2b", "claim in a later month")
    assert has_element?(view, "#gst-accept-not-claimable", "close the bill")

    view |> element("#gst-accept-await-2b") |> render_click()
    assert render(view) =~ "Kept — awaiting vendor&#39;s 2B"

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, period)
    workings = Resolutions.workings(month)
    assert workings.summary["accepted_unmatched"] == 1
    assert workings.itc["claimable_paise"] == 0

    assert Enum.any?(Resolutions.list(month.id), fn resolution ->
             resolution.verb == "accept_unmatched" and
               resolution.payload["reason"] == "await_2b"
           end)

    {:ok, today, _html} = live(conn, ~p"/today")
    refute has_element?(today, "#today-row-#{client.id}-#{period}", "to decide")

    {:ok, month_view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}")
    assert has_element?(month_view, "#month-door-bring-sales", "Bring in the sales bills")

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    assert has_element?(view, "#gst-accept-await-2b")

    view |> element("#gst-accept-not-claimable") |> render_click()
    assert render(view) =~ "Not claimable this month"
  end

  test "a 2B-only bill can be chased, dismissed, and reopened", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-03"

    gstr2b =
      g2b(%{
        "vendor_name" => "PORTAL VENDOR",
        "invoice_number" => "PORTAL-9",
        "total_paise" => 2_360_000
      })

    recon = Recon.reconcile([], [gstr2b])
    month = put_recon!(org, client, period, [], recon)
    ref = Recon.gstr2b_ref(gstr2b)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#queue-g2b-#{ref}")

    # A bill nobody sent is not a decision this reviewer can make, so it groups
    # as collection and never enters the progress denominator.
    assert has_element?(view, "#gst-exception-group-collection", "Bills to collect")
    assert has_element?(view, "#gst-exception-group-collection", "There is no scan to open")

    # Nila's position on the group: the treatment for a bill nobody sent is a
    # request, and the basis is what the portal reported.
    assert has_element?(
             view,
             "#gst-exception-group-collection",
             "Request the 1 missing bill from the client"
           )

    refute has_element?(view, "#gst-exception-group-decisions")
    refute has_element?(view, "#gst-exceptions-progress")
    assert has_element?(view, "#gst-exceptions", "1 bill to collect")
    assert has_element?(view, "#gst-exception-gstr2b", "Reported in GSTR-2B")
    refute render(view) =~ "isn&#39;t wired"

    view |> element("#gst-ask-client") |> render_click()
    assert has_element?(view, "#gst-missing-bill-modal")
    assert render(view) =~ "PORTAL VENDOR"
    assert render(view) =~ "PORTAL-9"

    view |> element("#gst-missing-bill-mark-sent") |> render_click()
    assert render(view) =~ "asked today"
    assert {:ok, ask} = Chase.last_ask(org.id, client.id, period)
    assert ask.body =~ "PORTAL-9"

    view |> element("#gst-dismiss-2b") |> render_click()
    assert render(view) =~ "Dismissed — not ours"
    assert Enum.any?(Resolutions.list(month.id), &(&1.verb == "dismiss_2b"))
    assert Resolutions.workings(month).recon["in_2b_not_books"] == []
    assert Chase.gaps(month).in_2b_not_books == []

    view |> element("#gst-exception-outcome button", "Undo") |> render_click()
    assert has_element?(view, "#gst-dismiss-2b")
  end

  test "an unknown books reason still falls back to recorded unmatched decisions", %{
    conn: conn,
    org: org,
    client: client
  } do
    period = "2026-04"
    books = books(%{"id" => "future_01", "invoice_number" => "FUTURE-1"})
    recon = Recon.reconcile([books], [])

    recon =
      update_in(recon, ["in_books_not_2b", Access.at(0), "reason"], fn reason ->
        %{reason | "code" => "future_engine_reason"}
      end)

    put_recon!(org, client, period, [books], recon)

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/#{period}/exceptions")

    assert has_element?(view, "#gst-accept-await-2b")
    assert has_element?(view, "#gst-accept-not-claimable")
    refute render(view) =~ "isn&#39;t wired"
  end

  test "another org cannot open the month", %{conn: conn, client: client} do
    %{user: other_user} = user_with_org_fixture()

    # Still bounced to /today, not to the month: the client belongs to somebody
    # else, so there is no month here to send them to.
    assert {:error, {:live_redirect, %{to: "/today"}}} =
             conn
             |> log_in_user(other_user)
             |> live(~p"/gst/#{client.id}/#{@period}/exceptions")
  end

  test "a month with no purchase side goes to the month, not away", %{
    conn: conn,
    client: client
  } do
    # This queue is the purchase workbench, so a sales-only month has nothing to
    # render here. It said "That month isn't available" and threw the reviewer
    # back to the work list that had just advertised it as "8 sales issues" — a
    # true statement about our tables, and a false one about the month.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/gst/#{client.id}/2099-01/exceptions")

    assert to == "/gst/#{client.id}/2099-01"
  end

  test "blocking a recommended duplicate credit reduces claimable ITC and logs it", %{
    conn: conn,
    org: org,
    client: client
  } do
    # Two identical scans of the same bill -> the flag engine recomputes a
    # duplicate_invoice flag, and the ITC panel recommends blocking one copy.
    dup = fn id ->
      %{
        "id" => id,
        "vendor_name" => "National Electric",
        "vendor_gstin" => @gstin,
        "invoice_number" => "254111",
        "invoice_date" => ~D[2025-10-06],
        "taxable_paise" => 3_500,
        "tax_paise" => %{"cgst" => 315, "sgst" => 315, "igst" => 0},
        "total_paise" => 4_130,
        "images" => [],
        "pages" => [if(id == "d1", do: 3, else: 9)]
      }
    end

    g2b = %{
      "vendor_gstin" => @gstin,
      "invoice_number" => "254111",
      "taxable_paise" => 3_500,
      "tax_paise" => %{"cgst" => 315, "sgst" => 315, "igst" => 0},
      "total_paise" => 4_130,
      "pos" => "33"
    }

    recon = Recon.reconcile([dup.("d1"), dup.("d2")], [g2b])
    rows = Register.rows([dup.("d1"), dup.("d2")], recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2025-11",
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    {:ok, view, _html} = live(conn, ~p"/gst/#{client.id}/2025-11/exceptions")

    assert has_element?(view, "#gst-itc-panel")
    block_id = "d1:duplicate_invoice"

    view
    |> element(~s|button[phx-click="block_itc"][phx-value-block-id="#{block_id}"]|)
    |> render_click()

    workings = Resolutions.workings(month)
    # one of two ₹6.30 copies blocked -> ₹6.30 (630 paise) removed
    assert workings.itc["blocked_paise"] == 630
    assert [res] = Resolutions.list(month.id)
    assert res.verb == "block_itc"
    assert res.payload["block_id"] == block_id
  end
end
