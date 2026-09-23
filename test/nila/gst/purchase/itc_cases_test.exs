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

    assert raw.payload["tax_paise"] == Map.put(bill["tax_paise"], "cess", 0)

    {:ok, _} =
      Resolutions.record_many_and_refresh(
        april,
        [%{"verb" => "reopen", "books_id" => bill["id"]}],
        context.user.id
      )

    assert [reopened] = june |> ItcCases.list_for_month() |> ItcCases.carried_books()
    assert reopened["tax_paise"] == Map.put(bill["tax_paise"], "cess", 0)
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

    # Moving historical membership does not enroll an undecided bill in June.
    assert [] == ItcCases.list_for_month(june)

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

  test "signoff rejects an older saved cess claim or deferral", context do
    heads = %{"cgst" => 4000, "sgst" => 4000, "igst" => 0, "cess" => 2000}
    portal = invoice(nil, "OLD-CESS", ~D[2025-07-12]) |> Map.put("tax_paise", heads)
    month = put_month!(context, "2026-08", [Map.put(portal, "id", "OLD-CESS-BOOK")], [portal])
    [line] = ItcCases.list_for_month(month)

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        client_month_id: month.id,
        org_id: context.org.id,
        signed_by_id: context.user.id,
        snapshot: %{}
      })

    for choice <- ~w(claim later) do
      {:ok, payload} =
        Nila.Gst.Purchase.ItcTreatment.build(heads, %{
          "choice" => choice,
          "later_reason" => "review_pending"
        })

      Repo.insert!(%ItcCaseEvent{
        case_id: line.case_id,
        effective_client_month_id: month.id,
        org_id: context.org.id,
        decided_by_id: context.user.id,
        event_type: "treatment_decided",
        payload: payload
      })

      fresh = ItcCases.list_for_month(month)

      assert {:error, :cess_review_required} =
               ItcCases.reserve_claims(signoff, month, fresh, %{"blocks" => []})

      assert [preserved] = fresh
      assert preserved.tax_heads == heads
    end
  end

  test "cess remains source evidence and cannot be claimed or deferred", context do
    heads = %{"cgst" => 4000, "sgst" => 4000, "igst" => 0, "cess" => 2000}
    portal = invoice(nil, "CESS-1", ~D[2026-08-12]) |> Map.put("tax_paise", heads)
    month = put_month!(context, "2026-08", [Map.put(portal, "id", "BOOK-CESS")], [portal])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)

    for choice <- ~w(claim later) do
      assert {:error, :cess_review_required} =
               ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
                 "choice" => choice,
                 "later_reason" => "review_pending"
               })
    end

    assert {:ok, %{workings: workings}} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "split",
               "claim" => %{"cgst" => 4000, "sgst" => 4000, "igst" => 0, "cess" => 0},
               "later" => Nila.Gst.Purchase.ItcTreatment.zero(),
               "exclude" => %{"cgst" => 0, "sgst" => 0, "igst" => 0, "cess" => 2000},
               "exclude_reason" => "blocked_credit"
             })

    assert [treated] = workings.case_lines
    assert treated.tax_heads == heads
    assert treated.treatment_heads["claim"]["cess"] == 0
    assert treated.treatment_heads["exclude"]["cess"] == 2000
  end

  test "historical intake stays in its source month until deliberately deferred", context do
    old = put_month!(context, "2020-08", [], [invoice(nil, "HISTORY", ~D[2020-08-12])])
    september = put_month!(context, "2026-09", [], [])
    assert [original] = ItcCases.list_for_month(old)
    assert original.treatment == "undecided"
    assert [] == ItcCases.list_for_month(september)
    assert [] == Resolutions.workings(september).case_lines
    assert [^original] = ItcCases.list_for_month(old)
  end

  test "explicit treatment carries only the outstanding amount across months", context do
    heads = %{"cgst" => 5000, "sgst" => 5000, "igst" => 0, "cess" => 0}
    portal = invoice(nil, "CARRY-1", ~D[2026-08-12]) |> Map.put("tax_paise", heads)
    august = put_month!(context, "2026-08", [Map.put(portal, "id", "BOOK-CARRY")], [portal])
    [line] = ItcCases.list_for_month(august)
    scope = Scope.for_user(context.user)
    assert line.treatment == "undecided"

    assert [] ==
             ItcCases.list_for_month(%Nila.Gst.Purchase.Month{
               org_id: context.org.id,
               client_id: context.client.id,
               period: "2026-09"
             })

    assert {:ok, _} =
             ItcDecisions.apply(scope, context.client.id, "2026-08", [line.case_id], %{
               "choice" => "later",
               "later_reason" => "review_pending"
             })

    virtual = %Nila.Gst.Purchase.Month{
      org_id: context.org.id,
      client_id: context.client.id,
      period: "2026-09"
    }

    assert [carried] = ItcCases.list_for_month(virtual)
    assert carried.treatment_heads["later"] == heads

    assert {:ok, %{month: september}} =
             ItcDecisions.apply(scope, context.client.id, "2026-09", [line.case_id], %{
               "choice" => "split",
               "claim" => %{"cgst" => 3000, "sgst" => 3000, "igst" => 0, "cess" => 0},
               "later" => %{"cgst" => 1000, "sgst" => 1000, "igst" => 0, "cess" => 0},
               "exclude" => %{"cgst" => 1000, "sgst" => 1000, "igst" => 0, "cess" => 0},
               "later_reason" => "review_pending",
               "exclude_reason" => "blocked_credit"
             })

    [september_line] = ItcCases.list_for_month(september)
    assert Enum.sum(Map.values(september_line.treatment_heads["claim"])) == 6000
    assert [october] = ItcCases.list_for_month(%{virtual | period: "2026-10"})

    assert october.outstanding_heads == %{
             "cgst" => 1000,
             "sgst" => 1000,
             "igst" => 0,
             "cess" => 0
           }

    assert october.treatment_heads["later"] == october.outstanding_heads
    assert [november] = ItcCases.list_for_month(%{virtual | period: "2026-11"})
    assert november.outstanding_heads == october.outstanding_heads
    assert [historical] = ItcCases.list_for_month(august)
    assert historical.treatment_heads["later"] == heads

    assert {:error, :later_treatment_exists} =
             ItcDecisions.apply(scope, context.client.id, "2026-08", [line.case_id], %{
               "choice" => "claim"
             })

    events = Repo.all(from e in ItcCaseEvent, where: e.case_id == ^line.case_id)
    assert Enum.all?(events, &(&1.decided_by_id == context.user.id))
  end

  test "later and exclusion do not assert missing document possession", context do
    portal = invoice(nil, "DOC-1", ~D[2026-04-12])
    month = put_month!(context, "2026-04", [], [portal])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)

    assert {:error, :claim_not_available} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "claim"
             })

    assert {:error, :reason_required} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "exclude"
             })

    assert {:ok, %{workings: workings}} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "exclude",
               "exclude_reason" => "personal"
             })

    assert [excluded] = workings.case_lines
    assert excluded.treatment == "exclude"
    assert excluded.document_state == "unknown"
    assert ItcCases.documents_settled?(workings.case_lines)

    assert {:error, :invalid_selection} =
             ItcDecisions.apply(
               scope,
               context.client.id,
               month.period,
               [line.case_id, 99_999_999],
               %{"choice" => "later", "later_reason" => "review_pending"}
             )

    viewer = %{scope | membership: %{scope.membership | role: "viewer"}}

    assert {:error, :forbidden} =
             ItcDecisions.apply(viewer, context.client.id, month.period, [line.case_id], %{
               "choice" => "later"
             })

    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    assert {:error, :signed_off} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "later",
               "later_reason" => "review_pending"
             })
  end

  test "partial claims reserve separate months and cannot reserve the same credit twice",
       context do
    portal = invoice(nil, "PARTIAL-1", ~D[2026-08-12])
    month = put_month!(context, "2026-08", [Map.put(portal, "id", "PARTIAL-BOOK")], [portal])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)
    half = %{"cgst" => 4500, "sgst" => 4500, "igst" => 0, "cess" => 0}
    zero = Nila.Gst.Purchase.ItcTreatment.zero()

    assert {:ok, first} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "split",
               "claim" => half,
               "later" => half,
               "exclude" => zero,
               "later_reason" => "review_pending"
             })

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        client_month_id: month.id,
        org_id: context.org.id,
        signed_by_id: context.user.id,
        snapshot: %{}
      })

    assert :ok =
             ItcCases.reserve_claims(
               signoff,
               month,
               first.workings.case_lines,
               first.workings.itc
             )

    assert {:error, :signed_off} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "claim"
             })

    assert {:ok, second} =
             ItcDecisions.apply(scope, context.client.id, "2026-09", [line.case_id], %{
               "choice" => "claim"
             })

    next_signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        client_month_id: second.month.id,
        org_id: context.org.id,
        signed_by_id: context.user.id,
        snapshot: %{}
      })

    assert :ok =
             ItcCases.reserve_claims(
               next_signoff,
               second.month,
               second.workings.case_lines,
               second.workings.itc
             )

    assert {:error, {:itc_already_allocated, [_]}} =
             ItcCases.reserve_claims(
               next_signoff,
               second.month,
               second.workings.case_lines,
               second.workings.itc
             )

    claims =
      Repo.all(from a in Nila.Gst.Purchase.ItcAllocation, where: a.case_id == ^line.case_id)

    assert length(claims) == 2
    assert Enum.sum(Enum.map(claims, & &1.tax_paise)) == 18000

    assert [] =
             ItcCases.list_for_month(%Nila.Gst.Purchase.Month{
               org_id: context.org.id,
               client_id: context.client.id,
               period: "2026-10"
             })
  end

  test "source moves cannot duplicate an already decided treatment", context do
    portal = invoice(nil, "SOURCE-1", ~D[2026-04-12])

    month =
      put_month!(context, "2026-04", [invoice("BOOK-OTHER", "OTHER", ~D[2026-04-12])], [portal])

    lines = ItcCases.list_for_month(month)
    line = Enum.find(lines, & &1.has_gstr2b?)
    target = Enum.find(lines, & &1.has_books?)

    assert {:ok, _} =
             ItcDecisions.apply(
               Scope.for_user(context.user),
               context.client.id,
               month.period,
               [line.case_id],
               %{"choice" => "later", "later_reason" => "awaiting_document"}
             )

    source =
      Repo.one!(
        from source in ItcSource,
          where: source.client_month_id == ^month.id and source.kind == "gstr2b"
      )

    assert {:error, :treatment_prevents_source_move} =
             ItcCases.move_source(
               month,
               source.id,
               target.case_id,
               "reconciliation_match",
               context.user.id
             )

    assert Enum.find(ItcCases.list_for_month(month), & &1.has_gstr2b?).case_id == line.case_id
  end

  test "a signed carried balance prevents an earlier treatment changing", context do
    portal = invoice(nil, "SIGNED-CARRY", ~D[2026-08-12])
    august = put_month!(context, "2026-08", [], [portal])
    [line] = ItcCases.list_for_month(august)
    scope = Scope.for_user(context.user)

    assert {:ok, _} =
             ItcDecisions.apply(scope, context.client.id, "2026-08", [line.case_id], %{
               "choice" => "later",
               "later_reason" => "awaiting_document"
             })

    september = put_month!(context, "2026-09", [], [])
    lines = ItcCases.list_for_month(september)

    Repo.insert!(%Nila.Gst.Filing.Signoff{
      client_month_id: september.id,
      org_id: context.org.id,
      signed_by_id: context.user.id,
      snapshot: %{"case_lines" => lines |> Jason.encode!() |> Jason.decode!()}
    })

    assert {:error, :later_signed_treatment} =
             ItcDecisions.apply(scope, context.client.id, "2026-08", [line.case_id], %{
               "choice" => "exclude",
               "exclude_reason" => "personal"
             })

    assert {:error, :later_signed_treatment} =
             ItcCases.record_event(august, line.case_id, "client_holds_document", context.user.id)

    assert {:error, :later_signed_treatment} =
             ItcCases.insert_event(august, line.case_id, "document_not_held", context.user.id)
  end

  test "a carried portal credit can receive its invoice in the current month", context do
    portal = invoice(nil, "HELD-CARRY", ~D[2026-08-12])
    august = put_month!(context, "2026-08", [], [portal])
    [line] = ItcCases.list_for_month(august)
    scope = Scope.for_user(context.user)

    assert {:ok, _} =
             ItcDecisions.apply(scope, context.client.id, "2026-08", [line.case_id], %{
               "choice" => "later",
               "later_reason" => "awaiting_document"
             })

    Repo.insert!(%Nila.Gst.Filing.Signoff{
      client_month_id: august.id,
      org_id: context.org.id,
      signed_by_id: context.user.id,
      snapshot: %{}
    })

    assert {:ok, %{workings: workings}} =
             ItcDecisions.record_document(scope, context.client.id, "2026-09", line.case_id)

    assert [held] = workings.case_lines
    assert held.document_state == "held"
    assert held.evidence_state == "complete"

    assert {:ok, _} =
             ItcDecisions.apply(scope, context.client.id, "2026-09", [line.case_id], %{
               "choice" => "claim"
             })

    assert [historical] = ItcCases.list_for_month(august)
    assert historical.document_state == "unknown"
    assert historical.treatment == "later"

    event =
      Repo.one!(
        from e in ItcCaseEvent,
          where: e.case_id == ^line.case_id and e.event_type == "client_holds_document"
      )

    assert event.decided_by_id == context.user.id
    assert event.effective_client_month_id != august.id
  end

  test "resync cannot remove the source of a reviewed outstanding credit", context do
    portal = invoice(nil, "KEEP-SOURCE", ~D[2026-08-12])
    month = put_month!(context, "2026-08", [], [portal])
    [line] = ItcCases.list_for_month(month)

    assert {:ok, _} =
             ItcDecisions.apply(
               Scope.for_user(context.user),
               context.client.id,
               month.period,
               [line.case_id],
               %{"choice" => "later", "later_reason" => "awaiting_document"}
             )

    assert {:error, :treated_source_cannot_be_removed} =
             ItcCases.sync_month(month, Reconciliation.reconcile([], []))

    assert :ok = ItcCases.sync_month(month, month.recon)
    assert [preserved] = ItcCases.list_for_month(month)
    assert preserved.case_id == line.case_id
    assert preserved.has_gstr2b?
  end

  test "claim directly reviews changed amounts without an intermediate deferral", context do
    portal = invoice(nil, "REVIEW-CHANGED", ~D[2026-08-12])
    month = put_month!(context, "2026-08", [Map.put(portal, "id", "CHANGED-BOOK")], [portal])
    [line] = ItcCases.list_for_month(month)
    scope = Scope.for_user(context.user)

    assert {:ok, _} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "claim"
             })

    revised_heads = %{"cgst" => 10000, "sgst" => 10000, "igst" => 0, "cess" => 0}

    for source <- Repo.all(from s in ItcSource, where: s.client_month_id == ^month.id) do
      source
      |> Ecto.Changeset.change(payload: Map.put(source.payload, "tax_paise", revised_heads))
      |> Repo.update!()
    end

    assert [stale] = ItcCases.list_for_month(month)
    assert stale.treatment_stale?
    assert stale.claimable?

    assert stale.treatment_heads["claim"] == %{
             "cgst" => 9000,
             "sgst" => 9000,
             "igst" => 0,
             "cess" => 0
           }

    assert {:ok, %{workings: workings}} =
             ItcDecisions.apply(scope, context.client.id, month.period, [line.case_id], %{
               "choice" => "claim"
             })

    assert [reviewed] = workings.case_lines
    refute reviewed.treatment_stale?
    assert reviewed.treatment_heads["claim"] == revised_heads

    for source <- Repo.all(from s in ItcSource, where: s.client_month_id == ^month.id) do
      source
      |> Ecto.Changeset.change(
        payload: Map.put(source.payload, "tax_paise", Nila.Gst.Purchase.ItcTreatment.zero())
      )
      |> Repo.update!()
    end

    assert [negative] =
             ItcCases.list_for_month(%Nila.Gst.Purchase.Month{
               org_id: context.org.id,
               client_id: context.client.id,
               period: "2026-09"
             })

    assert negative.treatment_stale?
    assert negative.outstanding_heads["cgst"] == -10000
  end

  test "a blocked debit note does not block an invoice with the same supplier name and number",
       context do
    bill = invoice("INV-TYPE", "SAME-1", ~D[2026-08-12])

    debit =
      bill
      |> Map.put("id", "DEBIT-TYPE")
      |> Map.put("document_type", "debit_note")
      |> Map.put("vendor_gstin", "27AAPFU0939F1ZV")

    month =
      put_month!(context, "2026-08", [bill, debit], [
        Map.put(bill, "id", nil),
        Map.put(debit, "id", nil)
      ])

    workings = Resolutions.workings(month)
    assert Enum.any?(workings.itc["blocks"], &(&1["document_type"] == "debit_note"))
    line = Enum.find(workings.case_lines, &(&1.document_type == "invoice"))
    assert line.claimable?

    assert {:ok, %{workings: updated}} =
             ItcDecisions.apply(
               Scope.for_user(context.user),
               context.client.id,
               month.period,
               [line.case_id],
               %{"choice" => "claim"}
             )

    assert updated.itc["current_claim_paise"] == 18_000
  end

  test "ITC blocks follow source rows after invoice identifiers are corrected" do
    line = %{
      id: "itc-case-12",
      books_invoices: [%{"id" => "BOOK-12"}],
      invoice_number: "ORIGINAL",
      supplier_gstin: "33AAACS9999A1Z9"
    }

    block = %{
      "state" => "blocked",
      "source_row_ids" => ["BOOK-12"],
      "invoice_number" => "CORRECTED",
      "vendor" => "Corrected supplier"
    }

    assert ItcCases.block_applies?(block, line)
    assert ItcCases.block_applies?(%{block | "source_row_ids" => ["itc-case-12"]}, line)
    refute ItcCases.block_applies?(%{block | "source_row_ids" => ["OTHER-BOOK"]}, line)
    refute ItcCases.block_applies?(%{block | "state" => "allowed"}, line)
  end

  test "supplier name spelling cannot bypass an ITC block", context do
    bill =
      invoice("BLOCK-NAME", "BLOCK-1", ~D[2026-08-12])
      |> Map.put("vendor_gstin", "27AAPFU0939F1ZV")

    portal = bill |> Map.put("id", nil) |> Map.put("vendor_name", "SHARMA STEELS PRIVATE LIMITED")
    month = put_month!(context, "2026-08", [bill], [portal])
    workings = Resolutions.workings(month)
    assert Enum.any?(workings.itc["blocks"], &(&1["state"] in ~w(blocked recommended)))
    [line] = workings.case_lines
    refute line.claimable?

    assert {:error, :claim_not_available} =
             ItcDecisions.apply(
               Scope.for_user(context.user),
               context.client.id,
               month.period,
               [line.case_id],
               %{"choice" => "claim"}
             )

    {:ok, payload} =
      Nila.Gst.Purchase.ItcTreatment.build(line.outstanding_heads, %{"choice" => "claim"})

    Repo.insert!(%ItcCaseEvent{
      case_id: line.case_id,
      effective_client_month_id: month.id,
      org_id: context.org.id,
      decided_by_id: context.user.id,
      event_type: "treatment_decided",
      payload: payload
    })

    fresh = Resolutions.workings(month)

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        client_month_id: month.id,
        org_id: context.org.id,
        signed_by_id: context.user.id,
        snapshot: %{}
      })

    assert {:error, {:itc_already_allocated, [_]}} =
             ItcCases.reserve_claims(signoff, month, fresh.case_lines, fresh.itc)
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
