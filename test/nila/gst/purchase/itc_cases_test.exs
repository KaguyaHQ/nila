defmodule Nila.Gst.Purchase.ItcCasesTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Accounts.Scope
  alias Nila.Gst.Purchase.ItcDecisions

  alias Nila.Gst.Purchase.{
    ItcCase,
    ItcCaseEvent,
    ItcCases,
    ItcSource,
    ItcSourceCaseEvent,
    Months,
    Reconciliation,
    Register,
    Resolutions
  }

  alias Nila.Repo

  @gstin "33AAACS1234A1Z9"

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin
      })

    %{user: user, org: org, client: client}
  end

  test "an April bill joins a June 2B without becoming a June purchase", context do
    bill = invoice("BOOK-1", "INV-42", ~D[2026-04-12])
    april = put_month!(context, "2026-04", [bill], [])

    assert [april_line] = ItcCases.list_for_month(april)
    assert april_line.evidence_state == "awaiting_2b"
    assert april_line.books_periods == ["2026-04"]
    assert april_line.gstr2b_periods == []

    portal = invoice(nil, "INV-42", ~D[2026-04-12])
    june = put_month!(context, "2026-06", [], [portal])

    assert [june_line] = ItcCases.list_for_month(june)
    assert june_line.case_id == april_line.case_id
    assert june_line.evidence_state == "complete"
    assert june_line.books_periods == ["2026-04"]
    assert june_line.gstr2b_periods == ["2026-06"]
    refute june_line.current_books?
    assert june_line.current_gstr2b?

    assert [historical_april] = ItcCases.list_for_month(april)
    assert historical_april.evidence_state == "awaiting_2b"
    assert historical_april.gstr2b_periods == []
  end

  test "carried purchases replay prior corrections without rewriting source evidence", context do
    bill =
      invoice("BOOK-HEADS", "INV-HEADS", ~D[2026-04-12])
      |> Map.put("vendor_gstin", "27AAPFU0939F1ZV")

    april = put_month!(context, "2026-04", [bill], [])
    corrected_heads = %{"cgst" => 0, "sgst" => 0, "igst" => 18_000}

    {:ok, _} =
      Resolutions.record_many_and_refresh(
        april,
        [
          %{
            "verb" => "correct_field",
            "books_id" => bill["id"],
            "payload" => %{
              "field" => "tax_paise",
              "from" => bill["tax_paise"],
              "to" => corrected_heads,
              "reason" => "Invoice shows IGST"
            }
          }
        ],
        context.user.id
      )

    portal = bill |> Map.put("id", nil) |> Map.put("tax_paise", corrected_heads)
    june = put_month!(context, "2026-06", [], [portal])

    workings = Resolutions.workings(june)
    assert [carried] = ItcCases.carried_books(workings.case_lines)
    assert carried["tax_paise"] == corrected_heads
    assert Enum.all?(workings.itc["blocks"], &(&1["code"] != "gstin_state_mismatch"))

    assert [%{"igst_paise" => 18_000, "cgst_paise" => 0}] =
             ItcCases.claim_rows(workings.case_lines, %{})

    raw =
      Repo.get_by!(ItcSource, client_month_id: april.id, kind: "books", source_ref: bill["id"])

    assert raw.payload["tax_paise"] == bill["tax_paise"]

    {:ok, _} =
      Resolutions.record_many_and_refresh(
        april,
        [%{"verb" => "reopen", "books_id" => bill["id"]}],
        context.user.id
      )

    assert [reopened] = june |> ItcCases.list_for_month() |> ItcCases.carried_books()
    assert reopened["tax_paise"] == bill["tax_paise"]
  end

  test "moving a source later does not rewrite its earlier case membership", context do
    bill = invoice("BOOK-1", "INV-77", ~D[2026-04-12])
    april = put_month!(context, "2026-04", [bill], [])
    assert [april_before] = ItcCases.list_for_month(april)

    june = put_month!(context, "2026-06", [], [])

    target_case =
      Repo.insert!(%ItcCase{
        org_id: context.org.id,
        client_id: context.client.id,
        document_type: "invoice",
        invoice_number: "INV-77",
        identity_state: "ambiguous"
      })

    source =
      Repo.get_by!(ItcSource,
        client_month_id: april.id,
        kind: "books",
        source_ref: bill["id"]
      )

    %{org: foreign_org} = user_with_org_fixture()

    {:ok, foreign_client} =
      Clients.create_client(%{
        org_id: foreign_org.id,
        name: "Foreign Client",
        type: "company",
        gstin: @gstin
      })

    foreign_case =
      Repo.insert!(%ItcCase{
        org_id: foreign_org.id,
        client_id: foreign_client.id,
        document_type: "invoice",
        identity_state: "provisional"
      })

    assert {:error, :not_found} =
             ItcCases.move_source(
               june,
               source.id,
               foreign_case.id,
               "identity_corrected",
               context.user.id
             )

    assert {:ok, %{from_case_id: old_case_id, to_case_id: new_case_id}} =
             ItcCases.move_source(
               june,
               source.id,
               target_case.id,
               "identity_corrected",
               context.user.id
             )

    assert old_case_id == april_before.case_id
    assert new_case_id == target_case.id

    assert {:ok, %{from_case_id: ^new_case_id, to_case_id: ^new_case_id}} =
             ItcCases.move_source(
               june,
               source.id,
               target_case.id,
               "identity_corrected",
               context.user.id
             )

    old_case = Repo.get!(ItcCase, old_case_id)

    old_case
    |> ItcCase.changeset(%{
      identity_state: "merged",
      merged_into_case_id: target_case.id
    })
    |> Repo.update!()

    %ItcCaseEvent{
      case_id: old_case.id,
      effective_client_month_id: june.id,
      org_id: context.org.id
    }
    |> ItcCaseEvent.changeset(%{
      event_type: "case_merged",
      payload: %{
        "merged_into_case_id" => target_case.id,
        "previous_identity_state" => old_case.identity_state
      }
    })
    |> Repo.insert!()

    assert [april_after] = ItcCases.list_for_month(april)
    assert april_after.case_id == april_before.case_id
    assert april_after.identity_state == april_before.identity_state
    assert april_after.books_periods == ["2026-04"]

    assert [june_line] = ItcCases.list_for_month(june)
    assert june_line.case_id == target_case.id
    assert june_line.books_periods == ["2026-04"]

    assert [initial_link, later_unlink, later_link] =
             Repo.all(
               from e in ItcSourceCaseEvent,
                 where: e.source_id == ^source.id,
                 order_by: [asc: e.inserted_at, asc: e.id]
             )

    assert initial_link.action == "linked"
    assert initial_link.reason == "source_discovered"
    assert later_unlink.action == "unlinked"
    assert later_unlink.reason == "identity_corrected"
    assert later_unlink.case_id == april_before.case_id
    assert later_unlink.decided_by_id == context.user.id
    assert later_link.action == "linked"
    assert later_link.reason == "identity_corrected"
    assert later_link.case_id == target_case.id
    assert later_link.decided_by_id == context.user.id
  end

  test "rejecting a pair separates its books and 2B sources", context do
    bill = invoice("BOOK-1", "INV-9", ~D[2026-04-12])
    portal = invoice(nil, "INV-9", ~D[2026-04-12])
    month = put_month!(context, "2026-04", [bill], [portal])

    assert [_one_case] = ItcCases.list_for_month(month)

    assert {:ok, _} =
             Resolutions.record(
               month,
               %{
                 "verb" => "reject_pair",
                 "books_id" => bill["id"],
                 "gstr2b_ref" => Reconciliation.gstr2b_ref(portal)
               },
               context.user.id
             )

    lines = ItcCases.list_for_month(month)
    assert length(lines) == 2
    assert Enum.all?(lines, &(&1.identity_state == "ambiguous"))
    assert Enum.any?(lines, &(&1.has_books? and not &1.has_gstr2b?))
    assert Enum.any?(lines, &(&1.has_gstr2b? and not &1.has_books?))
  end

  test "credit notes have separate identity and terminal reversal state", context do
    invoice = invoice("BOOK-INV", "SAME-1", ~D[2026-04-12])

    credit =
      invoice("BOOK-CN", "SAME-1", ~D[2026-04-12])
      |> Map.put("document_type", "credit_note")

    portal_credit =
      invoice(nil, "SAME-1", ~D[2026-04-12])
      |> Map.put("document_type", "credit_note")

    month = put_month!(context, "2026-04", [invoice, credit], [portal_credit])
    lines = ItcCases.list_for_month(month)

    assert length(lines) == 2
    assert Enum.map(lines, & &1.document_type) |> Enum.sort() == ["credit_note", "invoice"]

    credit_line = Enum.find(lines, &(&1.document_type == "credit_note"))
    assert credit_line.evidence_state == "complete"
    assert credit_line.eligibility_state == "not_applicable"
    assert credit_line.settlement_state == "reversed"
  end

  test "a conflicting duplicate fingerprint remains ambiguous", context do
    first = invoice("BOOK-1", "DUP-7", ~D[2026-04-12])

    second =
      invoice("BOOK-2", "DUP-7", ~D[2026-04-13])
      |> Map.put("tax_paise", %{"cgst" => 18_000, "sgst" => 18_000, "igst" => 0})

    month = put_month!(context, "2026-04", [first, second], [])
    lines = ItcCases.list_for_month(month)

    assert length(lines) == 2
    assert Enum.all?(lines, &(&1.identity_state == "ambiguous"))
    assert Enum.uniq_by(lines, & &1.case_id) == lines
  end

  test "resyncing an unchanged month creates no cases, sources, or membership events", context do
    bill = invoice("BOOK-1", "INV-42", ~D[2026-04-12])
    portal = invoice(nil, "INV-42", ~D[2026-04-12])
    month = put_month!(context, "2026-04", [bill], [portal])

    persisted_ids = {
      Repo.all(from c in ItcCase, order_by: c.id, select: c.id),
      Repo.all(from s in ItcSource, order_by: s.id, select: s.id),
      Repo.all(from e in ItcSourceCaseEvent, order_by: e.id, select: e.id)
    }

    assert :ok = ItcCases.sync_month(month, month.recon)

    assert persisted_ids == {
             Repo.all(from c in ItcCase, order_by: c.id, select: c.id),
             Repo.all(from s in ItcSource, order_by: s.id, select: s.id),
             Repo.all(from e in ItcSourceCaseEvent, order_by: e.id, select: e.id)
           }
  end

  test "claim exclusion is independent of documents, survives books and refetch, and can be reopened",
       context do
    portal = invoice(nil, "EXCLUDE-1", ~D[2026-04-12])
    month = put_month!(context, "2026-04", [], [portal])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)

    assert {:ok, %{workings: workings}} =
             ItcDecisions.exclude(
               scope,
               context.client.id,
               month.period,
               [line.case_id],
               "Personal use confirmed by client"
             )

    assert [excluded] = workings.case_lines
    assert excluded.claim_state == "not_claiming"
    assert excluded.claim_reason == "Personal use confirmed by client"

    event =
      Repo.one!(
        from e in ItcCaseEvent,
          where: e.case_id == ^line.case_id and e.event_type == "not_claiming_itc"
      )

    assert event.decided_by_id == context.user.id
    assert event.payload["reason"] == "Personal use confirmed by client"
    assert excluded.current_gstr2b?
    assert excluded.settlement_state != "excluded"

    {:ok, _} =
      ItcCases.record_event(month, line.case_id, "client_holds_document", context.user.id)

    assert [held] = ItcCases.list_for_month(month)
    assert held.document_state == "held"
    assert held.claim_state == "not_claiming"

    updated = put_month!(context, month.period, [Map.put(portal, "id", "BOOK-EXCLUDE")], [portal])
    assert [matched] = ItcCases.list_for_month(updated)
    assert matched.claim_state == "not_claiming"
    assert matched.has_books?

    assert {:ok, _} =
             ItcDecisions.exclude(
               scope,
               context.client.id,
               month.period,
               [line.case_id],
               "Personal use confirmed by client"
             )

    next = put_month!(context, "2026-05", [], [portal])
    assert [carried] = ItcCases.list_for_month(next)
    assert carried.claim_state == "not_claiming"

    assert {:ok, %{workings: restored}} =
             ItcDecisions.reopen(scope, context.client.id, next.period, [line.case_id])

    assert [%{claim_state: nil, claim_reason: nil}] = restored.case_lines
    assert [%{claim_state: "not_claiming"}] = ItcCases.list_for_month(updated)
  end

  test "bulk exclusions reject the whole selection for unknown cases, credit notes, and wrong tenants",
       context do
    portal = invoice(nil, "VALID-1", ~D[2026-04-12])
    credit = invoice(nil, "CREDIT-1", ~D[2026-04-12]) |> Map.put("document_type", "credit_note")
    month = put_month!(context, "2026-04", [], [portal, credit])
    lines = ItcCases.list_for_month(month)
    valid = Enum.find(lines, &(&1.document_type == "invoice"))
    ids = Enum.map(lines, & &1.case_id)
    scope = Scope.for_user(context.user)

    assert {:error, :invalid_selection} =
             ItcDecisions.exclude(scope, context.client.id, month.period, ids, "Reviewed")

    assert {:error, :invalid_selection} =
             ItcDecisions.exclude(
               scope,
               context.client.id,
               month.period,
               [valid.case_id, 9_999_999],
               "Reviewed"
             )

    assert {:error, :reason_required} =
             ItcDecisions.exclude(scope, context.client.id, month.period, [valid.case_id], " ")

    assert Enum.all?(ItcCases.list_for_month(month), &is_nil(&1.claim_state))
    other = user_with_org_fixture()

    assert {:error, :not_found} =
             ItcDecisions.exclude(
               Scope.for_user(other.user),
               context.client.id,
               month.period,
               [valid.case_id],
               "Reviewed"
             )
  end

  test "viewers and signed or filed months cannot change claim decisions", context do
    month = put_month!(context, "2026-04", [], [invoice(nil, "LOCK-1", ~D[2026-04-12])])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)
    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}

    assert {:error, :forbidden} =
             ItcDecisions.exclude(
               viewer,
               context.client.id,
               month.period,
               [line.case_id],
               "Reviewed"
             )

    assert {:error, :forbidden} =
             ItcDecisions.reopen(viewer, context.client.id, month.period, [line.case_id])

    {:ok, _} =
      ItcDecisions.exclude(scope, context.client.id, month.period, [line.case_id], "Reviewed")

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        client_month_id: month.id,
        org_id: context.org.id,
        signed_by_id: context.user.id,
        snapshot: %{}
      })

    assert {:error, :signed_off} =
             ItcDecisions.exclude(
               scope,
               context.client.id,
               month.period,
               [line.case_id],
               "Changed reason"
             )

    assert {:error, :signed_off} =
             ItcDecisions.reopen(scope, context.client.id, month.period, [line.case_id])

    Repo.delete!(signoff)
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :signed_off} =
             ItcDecisions.reopen(scope, context.client.id, month.period, [line.case_id])
  end

  test "claim events compare chronological timestamps across a second boundary", context do
    month = put_month!(context, "2026-04", [], [invoice(nil, "TIME-1", ~D[2026-04-12])])
    [line] = ItcCases.list_for_month(month)

    {:ok, excluded} =
      ItcCases.record_event(month, line.case_id, "not_claiming_itc", context.user.id, %{
        "reason" => "Reviewed"
      })

    {:ok, reopened} =
      ItcCases.record_event(month, line.case_id, "claim_reopened", context.user.id)

    excluded
    |> Ecto.Changeset.change(inserted_at: ~U[2026-04-15 10:00:01.900000Z])
    |> Repo.update!()

    reopened
    |> Ecto.Changeset.change(inserted_at: ~U[2026-04-15 10:00:02.100000Z])
    |> Repo.update!()

    assert [%{claim_state: nil}] = ItcCases.list_for_month(month)
  end

  test "explicit no-claim settles document gate without asserting document possession", context do
    month = put_month!(context, "2026-04", [], [invoice(nil, "DOC-1", ~D[2026-04-12])])
    [line] = ItcCases.list_for_month(month)
    refute ItcCases.documents_settled?([line])

    {:ok, result} =
      ItcDecisions.exclude(
        Scope.for_user(context.user),
        context.client.id,
        month.period,
        [line.case_id],
        "Not claiming"
      )

    assert ItcCases.documents_settled?(result.workings.case_lines)
    assert [%{document_state: "unknown"}] = result.workings.case_lines
  end

  test "moving a portal source carries exclusion even when older sources keep original case alive",
       context do
    portal = invoice(nil, "MOVE-1", ~D[2026-04-12])
    april = put_month!(context, "2026-04", [], [portal])
    [original] = ItcCases.list_for_month(april)

    {:ok, _} =
      ItcDecisions.exclude(
        Scope.for_user(context.user),
        context.client.id,
        april.period,
        [original.case_id],
        "Personal use"
      )

    may =
      put_month!(context, "2026-05", [invoice("BOOK-OTHER", "OTHER", ~D[2026-05-12])], [portal])

    target = Enum.find(ItcCases.list_for_month(may), &(&1.invoice_number == "OTHER"))

    source =
      Repo.one!(from s in ItcSource, where: s.client_month_id == ^may.id and s.kind == "gstr2b")

    {:ok, _} =
      ItcCases.move_source(
        may,
        source.id,
        target.case_id,
        "reconciliation_match",
        context.user.id
      )

    moved = Enum.find(ItcCases.list_for_month(may), &(&1.case_id == target.case_id))
    assert moved.claim_state == "not_claiming"
    assert moved.claim_reason == "Personal use"
    assert [%{claim_state: "not_claiming"}] = ItcCases.list_for_month(april)
  end

  test "rejecting a matched pair retains exclusion on separated portal record", context do
    portal = invoice(nil, "SPLIT-1", ~D[2026-04-12])
    book = Map.put(portal, "id", "BOOK-SPLIT")
    month = put_month!(context, "2026-04", [book], [portal])
    [line] = ItcCases.list_for_month(month)

    {:ok, _} =
      ItcDecisions.exclude(
        Scope.for_user(context.user),
        context.client.id,
        month.period,
        [line.case_id],
        "Not claiming"
      )

    assert :ok =
             ItcCases.separate_rejected_pairs(
               month,
               [
                 %{
                   "verb" => "reject_pair",
                   "books_id" => book["id"],
                   "gstr2b_ref" => Reconciliation.gstr2b_ref(portal)
                 }
               ],
               context.user.id
             )

    portal_line = Enum.find(ItcCases.list_for_month(month), & &1.current_gstr2b?)
    assert portal_line.case_id != line.case_id
    assert portal_line.claim_state == "not_claiming"

    {:ok, _} =
      ItcDecisions.reopen(Scope.for_user(context.user), context.client.id, month.period, [
        portal_line.case_id
      ])

    source =
      Repo.one!(from s in ItcSource, where: s.client_month_id == ^month.id and s.kind == "gstr2b")

    {:ok, _} =
      ItcCases.move_source(
        month,
        source.id,
        line.case_id,
        "reconciliation_match",
        context.user.id
      )

    restored = Enum.find(ItcCases.list_for_month(month), & &1.current_gstr2b?)
    assert restored.claim_state == nil
  end

  defp put_month!(context, period, books, gstr2b) do
    recon = Reconciliation.reconcile(books, gstr2b)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    month
  end

  defp invoice(id, number, date) do
    %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => "33AAACS9999A1Z9",
      "invoice_number" => number,
      "invoice_date" => date,
      "taxable_paise" => 100_000,
      "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
      "total_paise" => 118_000,
      "images" => [],
      "pages" => []
    }
  end
end
