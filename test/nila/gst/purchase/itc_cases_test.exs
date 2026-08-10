defmodule Nila.Gst.Purchase.ItcCasesTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients

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
