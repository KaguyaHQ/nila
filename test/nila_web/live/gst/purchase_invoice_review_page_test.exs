defmodule NilaWeb.Gst.PurchaseInvoiceReviewPageTest do
  use NilaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Nila.GstFixtures

  alias Nila.Gst.Purchase.{Groups, Months, Reconciliation, Register, Resolutions}
  alias NilaWeb.Gst.PurchaseWorkspace

  @period "2026-08"
  @gstin "33AAACS1234A1Z9"

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Breeze",
        type: "company",
        gstin: @gstin
      })

    %{conn: log_in_user(conn, user), user: user, org: org, client: client}
  end

  test "suggested pairing stays unresolved with queue navigation and no treatment", context do
    month =
      month!(
        context,
        [
          books("one", "1134"),
          Map.put(books("two", "OTHER-9"), "vendor_gstin", "33OTHER1234A1Z9")
        ],
        [portal("CHN-SER-1134")]
      )

    {:ok, view, _} = live(context.conn, review_path(context, "one", "all", "Sharma"))
    assert has_element?(view, "#purchase-comparison-0", "CHN-SER-1134")
    assert has_element?(view, "#purchase-comparison-0", "Different")
    assert has_element?(view, "#purchase-review-back[href*='filter=all'][href*='q=Sharma']")
    assert has_element?(view, "#purchase-review-back[href*='#purchase-open-']")
    assert has_element?(view, "#purchase-review-next[href*='filter=all'][href*='q=Sharma']")
    assert has_element?(view, "#purchase-review-queue [aria-current='page']")
    assert has_element?(view, "#purchase-pairing-pending", "Pairing needs review")
    refute has_element?(view, "#purchase-confirm-0")
    refute has_element?(view, "#purchase-treatment-form")
    render_click(view, "decide", %{"action" => "await_2b"})
    assert Resolutions.list(month.id) == []
  end

  test "forged candidate does not write a decision", context do
    month = month!(context, [books("one", "1134")], [portal("CHN-SER-1134")])
    {:ok, view, _} = live(context.conn, review_path(context, "one"))

    render_click(view, "decide", %{
      "action" => "confirm_pair",
      "books" => "one",
      "ref" => "other-client"
    })

    assert Resolutions.list(month.id) == []
    assert has_element?(view, "#purchase-invoice-review")
  end

  test "books-only pending records an attributed decision", context do
    month = month!(context, [books("one", "INV-1")], [])
    {:ok, view, _} = live(context.conn, review_path(context, "one"))
    view |> element("#purchase-await-2b") |> render_click()
    assert Resolutions.list(month.id) == []
    view |> form("#purchase-treatment-form") |> render_submit()

    assert_redirect(
      view,
      PurchaseWorkspace.list_path(context.client.id, @period, "needs_review", "")
    )

    assert [%{verb: "accept_unmatched", payload: %{"reason" => "await_2b"}}] =
             Resolutions.list(month.id)
  end

  test "viewer cannot decide through a forged event", context do
    month = month!(context, [books("one", "INV-1")], [])
    viewer = Nila.AccountsFixtures.user_fixture()
    {:ok, _} = Nila.Orgs.add_user(context.org, viewer.id, "viewer")
    {:ok, view, _} = live(log_in_user(build_conn(), viewer), review_path(context, "one"))
    assert has_element?(view, "#purchase-await-2b[disabled]")
    render_click(view, "decide", %{"action" => "await_2b"})
    assert Resolutions.list(month.id) == []
  end

  test "an amount mismatch stays visible without offering an unmatched ITC decision", context do
    month!(context, [books("one", "INV-1")], [
      Map.put(portal("INV-1"), "taxable_paise", 1_100_000)
    ])

    {:ok, view, _} = live(context.conn, review_path(context, "one", "mismatch"))
    assert has_element?(view, "#purchase-comparison-0", "Different")
    refute has_element?(view, "#purchase-challenge-0")
    refute has_element?(view, "#purchase-no-itc")
    assert has_element?(view, "#purchase-invoice-review", "amounts differ")
  end

  test "a recorded pending decision can be reopened", context do
    month = month!(context, [books("one", "INV-1")], [])

    {:ok, _} =
      Resolutions.record_many_and_refresh(
        month,
        [
          %{
            "verb" => "accept_unmatched",
            "books_id" => "one",
            "payload" => %{"reason" => "await_2b"}
          }
        ],
        context.user.id
      )

    {:ok, view, _} = live(context.conn, review_path(context, "one", "all"))
    view |> element("#purchase-reopen-decision") |> render_click()
    assert_redirect(view, PurchaseWorkspace.list_path(context.client.id, @period, "all", ""))
    assert Enum.any?(Resolutions.list(month.id), &(&1.verb == "reopen"))
  end

  test "corrected amounts recalculate matching, keep source and record reason", context do
    original = books("one", "INV-1")

    counterpart =
      Map.merge(portal("INV-1"), %{
        "taxable_paise" => 1_100_000,
        "tax_paise" => %{"cgst" => 99_000, "sgst" => 99_000, "igst" => 0},
        "total_paise" => 1_298_000
      })

    month = month!(context, [original], [counterpart])
    {:ok, view, _} = live(context.conn, review_path(context, "one", "mismatch"))
    view |> element("#purchase-correct-values-0") |> render_click()

    view
    |> form("#purchase-values-form",
      correction: %{
        taxable_paise: "11000",
        cgst: "990",
        sgst: "990",
        igst: "0",
        total_paise: "12980",
        reason: "Checked amounts against original invoice"
      }
    )
    |> render_submit()

    assert_redirect(view, PurchaseWorkspace.list_path(context.client.id, @period, "mismatch", ""))
    {:ok, refreshed} = Months.get_by_period(context.org.id, context.client.id, @period)
    assert [%{"books" => %{"taxable_paise" => 1_000_000}}] = refreshed.recon["value_mismatch"]

    assert [%{"books" => %{"taxable_paise" => 1_100_000}}] =
             Resolutions.workings(refreshed).recon["matched"]

    corrections = Resolutions.list(month.id)
    assert length(corrections) == 3

    assert Enum.all?(
             corrections,
             &(&1.decided_by_id == context.user.id and
                 &1.payload["reason"] == "Checked amounts against original invoice")
           )

    assert Enum.any?(
             corrections,
             &(&1.payload["field"] == "taxable_paise" and &1.payload["from"] == 1_000_000)
           )
  end

  test "ordinary invoices hide zero CESS comparison, correction and split controls", context do
    month!(context, [books("one", "INV-1")], [portal("INV-1")])
    {:ok, view, _} = live(context.conn, review_path(context, "one", "all"))
    refute has_element?(view, "#purchase-comparison-0", "CESS")
    view |> element("#purchase-correct-values-0") |> render_click()
    refute has_element?(view, "#correction_cess")
    render_click(view, "cancel-correction", %{})
    view |> element("#purchase-review-set-treatment") |> render_click()
    view |> element("#purchase-review-choice-split") |> render_click()
    refute has_element?(view, "#purchase-review-cess-claim")
    refute has_element?(view, "#purchase-review-cess-review")
  end

  test "CESS review disables whole claim and later while keeping split exclusion", context do
    original =
      books("one", "CESS-1")
      |> put_in(["tax_paise", "cess"], 2_000)
      |> Map.put("total_paise", 1_182_000)

    month!(context, [original], [Map.delete(original, "id")])
    {:ok, view, _} = live(context.conn, review_path(context, "one", "all"))
    assert has_element?(view, "#purchase-comparison-0", "CESS")
    view |> element("#purchase-review-set-treatment") |> render_click()
    assert has_element?(view, "#purchase-review-choice-claim[disabled]")
    assert has_element?(view, "#purchase-review-choice-later[disabled]")
    assert has_element?(view, "#purchase-review-cess-review", "cess")
    view |> element("#purchase-review-choice-split") |> render_click()
    assert has_element?(view, "#purchase-review-cess-claim[disabled][value='0.00']")
    assert has_element?(view, "#purchase-review-cess-later[disabled][value='0.00']")
    assert has_element?(view, "#purchase-review-cess-exclude:not([disabled])")
  end

  test "correcting taxable value preserves printed CESS", context do
    original =
      books("one", "CESS-1")
      |> put_in(["tax_paise", "cess"], 2_000)
      |> Map.put("total_paise", 1_182_000)

    month = month!(context, [original], [])
    {:ok, view, _} = live(context.conn, review_path(context, "one"))
    view |> element("#purchase-correct-values-0") |> render_click()
    assert has_element?(view, "#purchase-values-form", "CESS")

    view
    |> form("#purchase-values-form",
      correction: %{
        taxable_paise: "11000",
        cgst: "900",
        sgst: "900",
        igst: "0",
        cess: "20",
        total_paise: "12820",
        reason: "Checked invoice"
      }
    )
    |> render_submit()

    corrections = Resolutions.list(month.id)
    assert Enum.any?(corrections, &(&1.payload["field"] == "taxable_paise"))
    refute Enum.any?(corrections, &(&1.payload["field"] == "tax_paise"))
  end

  test "invalid correction amounts and missing reason do not write", context do
    month = month!(context, [books("one", "INV-1")], [])
    {:ok, view, _} = live(context.conn, review_path(context, "one"))
    view |> element("#purchase-correct-values-0") |> render_click()

    base = %{
      "taxable_paise" => "10000",
      "cgst" => "900",
      "sgst" => "900",
      "igst" => "0",
      "total_paise" => "11800",
      "reason" => "Checked invoice"
    }

    for params <- [
          Map.put(base, "taxable_paise", "-1"),
          Map.put(base, "cgst", "1.001"),
          Map.put(base, "reason", ""),
          Map.put(base, "total_paise", "1")
        ] do
      render_submit(view, "save-correction", %{"correction" => params})
      assert has_element?(view, "#purchase-correction-error")
      assert Resolutions.list(month.id) == []
    end
  end

  test "a month signed while correction is open rejects the stale form", context do
    month = month!(context, [books("one", "INV-1")], [portal("INV-1")])
    {:ok, view, _} = live(context.conn, review_path(context, "one", "all"))
    view |> element("#purchase-correct-values-0") |> render_click()

    case_id = hd(Nila.Gst.Purchase.ItcCases.list_for_month(month)).case_id

    {:ok, _} =
      Nila.Gst.Purchase.ItcDecisions.apply(
        Nila.Accounts.Scope.for_user(context.user),
        context.client.id,
        @period,
        [case_id],
        %{"choice" => "claim"}
      )

    {:ok, _} =
      Nila.Gst.Filing.Signoffs.sign_off(month, Nila.Accounts.Scope.for_user(context.user))

    view
    |> form("#purchase-values-form",
      correction: %{
        taxable_paise: "11000",
        cgst: "990",
        sgst: "990",
        igst: "0",
        total_paise: "12980",
        reason: "Checked original"
      }
    )
    |> render_submit()

    assert has_element?(view, "#purchase-correction-error")
    assert Resolutions.list(month.id) == []
  end

  test "another firm cannot open this purchase", context do
    month!(context, [books("one", "INV-1")], [])
    %{user: other} = user_with_org_fixture()

    assert {:error, {:live_redirect, %{to: "/clients"}}} =
             live(log_in_user(build_conn(), other), review_path(context, "one"))
  end

  test "signed month blocks a forged decision and shows the frozen comparison", context do
    month = month!(context, [books("one", "INV-1")], [portal("INV-1")])

    case_id = hd(Nila.Gst.Purchase.ItcCases.list_for_month(month)).case_id

    {:ok, _} =
      Nila.Gst.Purchase.ItcDecisions.apply(
        Nila.Accounts.Scope.for_user(context.user),
        context.client.id,
        @period,
        [case_id],
        %{"choice" => "claim"}
      )

    {:ok, _} =
      Nila.Gst.Filing.Signoffs.sign_off(month, Nila.Accounts.Scope.for_user(context.user))

    {:ok, view, _} = live(context.conn, review_path(context, "one", "all"))
    assert has_element?(view, "#purchase-review-locked")
    refute has_element?(view, "#purchase-challenge-0")
    assert has_element?(view, "#purchase-correct-values-0[disabled]")
    render_click(view, "decide", %{"action" => "await_2b"})
    assert Resolutions.list(month.id) == []
  end

  test "2B-only document decision is kept in the case ledger", context do
    month = month!(context, [], [portal("PORTAL-1")])
    review = month |> Resolutions.workings() |> Nila.Gst.Purchase.Review.project(month: month)
    item = hd(review.all)
    {:ok, view, _} = live(context.conn, review_path(context, item.id))
    assert has_element?(view, "#purchase-comparison-0", "PORTAL-1")

    assert has_element?(
             view,
             "#purchase-review-reason",
             "Reported in GSTR-2B. Import purchases to compare with books."
           )

    assert has_element?(view, "#purchase-review-queue", "Reported in GSTR-2B")
    view |> element("#purchase-document-missing") |> render_click()
    view |> form("#purchase-treatment-form") |> render_submit()

    assert_redirect(
      view,
      PurchaseWorkspace.list_path(context.client.id, @period, "needs_review", "")
    )

    updated = month |> Resolutions.workings() |> Nila.Gst.Purchase.Review.project(month: month)
    assert hd(updated.all).document_state == "not_held"
  end

  test "a 2B-only invoice can record document possession after Later and then Claim", context do
    month = month!(context, [], [portal("PORTAL-LATER")])
    item = hd(Nila.Gst.Purchase.Review.project(Resolutions.workings(month), month: month).all)
    path = review_path(context, item.id, "all")
    {:ok, view, _} = live(context.conn, path)
    view |> element("#purchase-review-set-treatment") |> render_click()
    view |> element("#purchase-review-choice-later") |> render_click()

    view
    |> form("#purchase-review-treatment-form", itc: %{later_reason: "review_pending"})
    |> render_submit()

    assert_redirect(view)

    {:ok, view, _} = live(context.conn, path)
    assert has_element?(view, "#purchase-document-held")
    view |> element("#purchase-document-held") |> render_click()
    view |> form("#purchase-treatment-form") |> render_submit()
    assert_redirect(view)

    {:ok, view, _} = live(context.conn, path)
    view |> element("#purchase-review-set-treatment") |> render_click()
    assert has_element?(view, "#purchase-review-choice-claim:not([disabled])")
    view |> element("#purchase-review-choice-claim") |> render_click()
    view |> form("#purchase-review-treatment-form") |> render_submit()
    assert_redirect(view)

    {:ok, workspace} =
      PurchaseWorkspace.load(
        Nila.Accounts.Scope.for_user(context.user),
        context.client.id,
        @period
      )

    updated = Nila.Gst.Purchase.Review.lookup(workspace.items, item.id)
    assert updated.document_state == "held"
    assert updated.treatment == "claim"
  end

  test "save and next advances to another unresolved item without losing filters", context do
    month = month!(context, [books("one", "INV-1"), books("two", "INV-2")], [])
    {:ok, view, _} = live(context.conn, review_path(context, "one", "books_only", "Sharma"))
    view |> form("#purchase-treatment-form") |> render_submit()
    assert has_element?(view, "#purchase-treatment-error")
    assert Resolutions.list(month.id) == []
    view |> element("#purchase-await-2b") |> render_click()
    view |> form("#purchase-treatment-form") |> render_submit()

    {:ok, workspace} =
      PurchaseWorkspace.load(
        Nila.Accounts.Scope.for_user(context.user),
        context.client.id,
        @period
      )

    next = Nila.Gst.Purchase.Review.lookup(workspace.items, "two")
    assert_redirect(view, review_path(context, next.id, "books_only", "Sharma"))
    assert [%{verb: "accept_unmatched", decided_by_id: author}] = Resolutions.list(month.id)
    assert author == context.user.id
  end

  test "skip does not record a decision", context do
    month = month!(context, [books("one", "INV-1"), books("two", "INV-2")], [])
    {:ok, view, _} = live(context.conn, review_path(context, "one"))
    assert has_element?(view, "#purchase-review-skip[href]")
    assert Resolutions.list(month.id) == []
  end

  test "a signoff after selecting a treatment prevents saving", context do
    month = month!(context, [], [portal("PORTAL-1")])
    item = hd(Nila.Gst.Purchase.Review.project(Resolutions.workings(month), month: month).all)
    {:ok, view, _} = live(context.conn, review_path(context, item.id))
    view |> element("#purchase-not-ours") |> render_click()
    # A concurrent lock must be checked again by the save, not just by the form.
    Nila.Repo.update!(Ecto.Changeset.change(month, filed_at: DateTime.utc_now()))
    view |> form("#purchase-treatment-form") |> render_submit()
    assert Resolutions.list(month.id) == []
    assert has_element?(view, "#purchase-treatment-form")
  end

  test "ITC on a secondary member of an uncertain group cannot be treated", context do
    secondary =
      books("two", "BOOK-B")
      |> Map.put("line_items", [%{"description" => "Furniture", "taxable_paise" => 1_000_000}])

    month =
      month!(context, [books("one", "BOOK-A"), secondary], [
        portal("PORTAL-1"),
        portal("PORTAL-2")
      ])

    {:ok, workspace} =
      PurchaseWorkspace.load(
        Nila.Accounts.Scope.for_user(context.user),
        context.client.id,
        @period
      )

    group = Nila.Gst.Purchase.Review.lookup(workspace.items, "two")
    assert group.member_ids == ["one", "two"]
    assert group.invoice_number == "BOOK-A"
    refute group.resolved
    assert group.candidates != []
    item = Enum.find(workspace.items, &(&1.kind == :itc and &1.invoice_number == "BOOK-B"))
    assert item.itc_block["block_id"] == "two:personal_expense_17_5"

    {:ok, view, _} = live(context.conn, review_path(context, item.id, "itc"))
    assert has_element?(view, "#purchase-pairing-pending", "Pairing needs review")
    refute has_element?(view, "#purchase-treatment-form")
    render_click(view, "choose-treatment", %{"action" => "allow_itc"})
    render_submit(view, "save-treatment", %{})
    assert Resolutions.list(month.id) == []

    for action <- ["allow_itc", "block_itc"] do
      render_click(view, "decide", %{"action" => action})
      assert Resolutions.list(month.id) == []
    end
  end

  defp review_path(c, id, filter \\ "needs_review", q \\ ""),
    do: PurchaseWorkspace.review_path(c.client.id, @period, id, filter, q)

  defp month!(c, books, counterparts) do
    gstr2b_arrived!(c.org, c.client, @period, counterparts)
    recon = Reconciliation.reconcile(books, counterparts)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: c.org.id,
        client_id: c.client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows, Groups.build(recon))
      })

    month
  end

  defp books(id, number), do: Map.put(portal(number), "id", id)

  defp portal(number),
    do: %{
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => @gstin,
      "invoice_number" => number,
      "invoice_date" => ~D[2026-08-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "images" => [],
      "pos" => "33"
    }
end
