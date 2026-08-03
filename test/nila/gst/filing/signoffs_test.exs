defmodule Nila.Gst.Filing.SignoffsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures
  import Nila.GstFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.{Confirmations, Dumps}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Purchase.Reconciliation, as: Recon
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings

  @period "2025-10"
  @gstin "33AAACS1234A1Z9"

  setup do
    %{user: owner, org: org, membership: owner_membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin,
        phone: "9876543210"
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

    # Reconciled against the portal's copy of the same bill, so the register is
    # settled. Signing is what these tests are about, and a month reconciled
    # against an empty 2B leaves every row unmatched — signable only while the
    # server had no register gate.
    gstr2b = %{
      "vendor_name" => books["vendor_name"],
      "vendor_gstin" => books["vendor_gstin"],
      "invoice_number" => books["invoice_number"],
      "invoice_date" => books["invoice_date"],
      "taxable_paise" => books["taxable_paise"],
      "tax_paise" => books["tax_paise"],
      "total_paise" => books["total_paise"]
    }

    recon = Recon.reconcile([books], [gstr2b])
    rows = Register.rows([books], recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    owner_scope = %Scope{user: owner, current_org: org, membership: owner_membership}

    _confirmation = confirm_sales_complete!(org, client, @period)

    %{org: org, client: client, month: month, owner_scope: owner_scope}
  end

  defp held_dump!(month, user_id, kind) do
    {:ok, dump} =
      Dumps.record(
        %{org_id: month.org_id, client_id: month.client_id, brought_in_by_id: user_id},
        %{period: month.period, kind: kind, file_keys: ["held/#{kind}.pdf"]}
      )

    Dumps.mark_held(dump)
  end

  test "owner signs off a worked month: state reviewed, frozen snapshot persisted", %{
    month: month,
    owner_scope: scope,
    org: org
  } do
    assert {:ok, signoff} = Signoffs.sign_off(month, scope)

    assert signoff.org_id == org.id
    assert signoff.client_month_id == month.id
    assert signoff.signed_by_id == scope.user.id

    for key <- ~w(summary itc gstr3b rows) do
      assert Map.has_key?(signoff.snapshot, key), "snapshot missing #{key}"
    end

    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert month.state == "reviewed"

    assert {:ok, latest} = Signoffs.latest_signoff(month.id)
    assert latest.id == signoff.id
    assert latest.signed_by.id == scope.user.id
  end

  test "purchase signoff snapshots the effective projection from the locked fresh month", %{
    month: stale_month,
    owner_scope: scope
  } do
    assert {:ok, _resolution} =
             Resolutions.record(
               stale_month,
               %{
                 "verb" => "accept_unmatched",
                 "books_id" => "page_01",
                 "payload" => %{"reason" => "await_2b"}
               },
               scope.user.id
             )

    {:ok, fresh_month} =
      ClientMonths.get_by_period(
        stale_month.org_id,
        stale_month.client_id,
        stale_month.period
      )

    expected = Resolutions.workings(fresh_month)
    assert {:ok, signoff} = Signoffs.sign_off(stale_month, scope)
    assert signoff.snapshot["rows"] == expected.rows
    assert signoff.snapshot["summary"] == expected.summary
    assert signoff.snapshot["itc"] == expected.itc
    assert signoff.snapshot["gstr3b"] == expected.gstr3b
  end

  # The GSTR-1 side has refused an unreviewed signature since it was written;
  # this one checked only permission, state and sales completeness, leaving the
  # register gate in the template. A signed 3B freezes the ITC snapshot, so
  # anything reaching this function directly could certify unreviewed credit.
  test "GSTR-3B refuses a signature while a decision is still open", %{
    org: org,
    client: client,
    month: month,
    owner_scope: scope
  } do
    books = %{
      "id" => "page_02",
      "vendor_name" => "Unknown Traders",
      "vendor_gstin" => "33AAACS9999A1Z9",
      "invoice_number" => "9001",
      "invoice_date" => ~D[2025-10-09],
      "taxable_paise" => 500_000,
      "tax_paise" => %{"cgst" => 45_000, "sgst" => 45_000, "igst" => 0},
      "total_paise" => 590_000,
      "images" => [],
      "pages" => [2]
    }

    # A books row with no 2B counterpart: a real decision, and one the queue
    # offers verbs for.
    recon = Recon.reconcile([books], [])
    rows = Register.rows([books], recon, %{})

    {:ok, unreviewed} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: month.period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    assert Register.need_decision(unreviewed.summary) > 0
    assert {:error, :not_reviewed} = Signoffs.sign_off(unreviewed, scope)
    assert {:error, :not_found} = Signoffs.latest_signoff(unreviewed.id)

    settled = settle_register!(unreviewed, scope.user.id)
    assert {:ok, _signoff} = Signoffs.sign_off(settled, scope)
  end

  test "GSTR-3B rejects open completeness and accepts an attributed override", %{
    month: month,
    client: client,
    owner_scope: scope
  } do
    {:ok, open_month} =
      ClientMonths.upsert(%{
        org_id: month.org_id,
        client_id: month.client_id,
        period: "2025-11",
        state: "worked",
        register_rows: month.register_rows,
        recon: month.recon,
        summary: month.summary
      })

    assert {:error, {:sales_intake_incomplete, :open}} =
             Signoffs.sign_off(open_month, scope)

    assert {:ok, _override} =
             Confirmations.record_override(scope, client.id, "2025-11", %{
               reason: "Client's records are known to be complete"
             })

    assert {:ok, _signoff} = Signoffs.sign_off(open_month, scope)
  end

  test "GSTR-3B rejects the latest client-no decision", %{
    month: month,
    client: client,
    owner_scope: scope
  } do
    assert {:ok, _no} =
             Confirmations.record_client(
               %{org_id: month.org_id},
               month.client_id,
               month.period,
               %{
                 decision: "client_no",
                 channel: "whatsapp",
                 source_ref: "wamid.client-no",
                 actor_phone: client.phone
               }
             )

    assert {:error, {:sales_intake_incomplete, :client_no}} =
             Signoffs.sign_off(month, scope)
  end

  test "the operator (member) cannot self-certify", %{month: month, org: org} do
    member = user_fixture()
    {:ok, membership} = Nila.Orgs.add_user(org, member.id, "member")
    member_scope = %Scope{user: member, current_org: org, membership: membership}

    assert {:error, :not_allowed} = Signoffs.sign_off(month, member_scope)
    assert {:error, :not_found} = Signoffs.latest_signoff(month.id)

    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert month.state == "worked"
  end

  test "signing an already-reviewed month errors even if later intake is stale", %{
    month: month,
    owner_scope: scope
  } do
    assert {:ok, _} = Signoffs.sign_off(month, scope)

    {:ok, _late} =
      Dumps.record(
        %{org_id: month.org_id, client_id: month.client_id},
        %{period: month.period, kind: "sales"}
      )

    {:ok, reviewed} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert {:error, :already_signed} = Signoffs.sign_off(reviewed, scope)
  end

  test "reopening a 3B signoff revokes it and demotes the month", %{
    month: month,
    owner_scope: scope
  } do
    {:ok, signoff} = Signoffs.sign_off(month, scope)

    assert {:ok, revoked} = Signoffs.reopen(signoff, scope)
    assert revoked.revoked_at
    assert revoked.revoked_by_id == scope.user.id

    assert {:error, :not_found} = Signoffs.latest_signoff(month.id)
    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert month.state == "worked"

    assert {:error, :already_revoked} = Signoffs.reopen(revoked, scope)
  end

  test "mark_filed requires a signature, records the filing, and locks reopen", %{
    month: month,
    owner_scope: scope
  } do
    assert {:error, :not_signed} = Signoffs.mark_filed(month, scope, "AA331025000001")

    {:ok, signoff} = Signoffs.sign_off(month, scope)
    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)

    assert {:ok, filed} = Signoffs.mark_filed(month, scope, "AA331025000001")
    assert filed.state == "filed"
    assert filed.filed_at
    assert filed.filed_by_id == scope.user.id
    assert filed.filing_arn == "AA331025000001"

    assert {:error, :already_filed} = Signoffs.mark_filed(filed, scope, nil)
    assert {:error, :filed} = Signoffs.reopen(signoff, scope)
  end

  test "filing GSTR-3B makes only held purchase-side dumps terminal", %{
    month: month,
    owner_scope: scope
  } do
    purchase = held_dump!(month, scope.user.id, "purchase")
    gstr2b = held_dump!(month, scope.user.id, "gstr2b")
    assert {:ok, _} = Signoffs.sign_off(month, scope)
    sales = held_dump!(month, scope.user.id, "sales")
    assert {:ok, _} = Signoffs.mark_filed(month, scope)

    assert {:ok, %{status: "after_filing"}} = Dumps.fetch(month.org_id, purchase.id)
    assert {:ok, %{status: "after_filing"}} = Dumps.fetch(month.org_id, gstr2b.id)
    assert {:ok, %{status: "held"}} = Dumps.fetch(month.org_id, sales.id)
  end

  test "a member cannot reopen", %{month: month, owner_scope: scope, org: org} do
    {:ok, signoff} = Signoffs.sign_off(month, scope)

    member = user_fixture()
    {:ok, membership} = Nila.Orgs.add_user(org, member.id, "member")
    member_scope = %Scope{user: member, current_org: org, membership: membership}

    assert {:error, :not_allowed} = Signoffs.reopen(signoff, member_scope)
    assert {:ok, _} = Signoffs.latest_signoff(month.id)
  end

  describe "GSTR-1 sign-off" do
    setup %{org: org, month: month} do
      {:ok, client} = Clients.get_client(org.id, month.client_id)

      work_dump!(org, client, @period, "sales", "%PDF-1.4 fake bytes")

      _confirmation = confirm_sales_complete!(org, client, @period)

      {:ok, sales_month} = SalesMonths.get_by_period(org.id, client.id, @period)
      %{sales_month: sales_month}
    end

    defp resolve_open_issues(sales_month, user_id) do
      SalesResolutions.workings(sales_month).issues
      |> Enum.filter(fn issue ->
        issue["status"] == "open" and issue["level"] not in ["info", "blocking"]
      end)
      |> Enum.each(fn issue ->
        {:ok, _} =
          SalesResolutions.record(
            sales_month,
            %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)},
            user_id
          )
      end)

      Nila.Repo.reload!(sales_month)
    end

    defp make_reviewed(sales_month, user_id) do
      sales_month = resolve_open_issues(sales_month, user_id)
      {:ok, reviewed} = SalesResolutions.mark_reviewed(sales_month)
      reviewed
    end

    test "requires the maker gate", %{sales_month: sales_month, owner_scope: scope} do
      assert {:error, :not_reviewed} = Signoffs.sign_off_gstr1(sales_month, scope)
    end

    test "maker review remains available while completeness is open", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      {:ok, open_month} =
        SalesMonths.upsert(%{
          org_id: sales_month.org_id,
          client_id: sales_month.client_id,
          period: "2025-11",
          state: "worked",
          cess_evaluated: sales_month.cess_evaluated,
          invoices: sales_month.invoices,
          derived_gstr1: sales_month.derived_gstr1,
          issues: sales_month.issues,
          summary: sales_month.summary
        })

      reviewed = make_reviewed(open_month, scope.user.id)
      assert reviewed.state == "reviewed"

      assert {:error, {:sales_intake_incomplete, :open}} =
               Signoffs.sign_off_gstr1(reviewed, scope)
    end

    test "GSTR-1 rejects a confirmation made stale by late active sales intake", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)

      {:ok, _late} =
        Dumps.record(
          %{org_id: reviewed.org_id, client_id: reviewed.client_id},
          %{period: reviewed.period, kind: "sales"}
        )

      assert {:error, {:sales_intake_incomplete, :stale}} =
               Signoffs.sign_off_gstr1(reviewed, scope)
    end

    test "approval directly freezes a reviewed draft with reviewer, time, and version", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      resolved = resolve_open_issues(sales_month, scope.user.id)
      assert resolved.state == "worked"

      assert {:ok, signoff} = Signoffs.sign_off_gstr1(resolved, scope)
      assert signoff.artifact == "gstr1"
      assert signoff.sales_month_id == sales_month.id
      assert signoff.signed_by_id == scope.user.id
      assert signoff.inserted_at

      for key <- ~w(invoices printed_invoices issues derived draft_version) do
        assert Map.has_key?(signoff.snapshot, key), "snapshot missing #{key}"
      end

      assert String.length(signoff.snapshot["draft_version"]) == 64

      assert {:ok, %{state: "reviewed"}} =
               SalesMonths.get_by_period(
                 sales_month.org_id,
                 sales_month.client_id,
                 sales_month.period
               )

      assert {:ok, latest} = Signoffs.latest_gstr1_signoff(sales_month.id)
      assert latest.id == signoff.id

      assert {:error, :already_signed} = Signoffs.sign_off_gstr1(resolved, scope)
    end

    test "cess must be evaluated before approval", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      resolved = resolve_open_issues(sales_month, scope.user.id)

      unresolved_cess =
        resolved |> Ecto.Changeset.change(cess_evaluated: false) |> Nila.Repo.update!()

      assert {:error, {:blocking_issues, ["cess_not_evaluated"]}} =
               Signoffs.sign_off_gstr1(unresolved_cess, scope)
    end

    test "a document the return has no table for cannot be signed", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)

      # Reviewed first, then the marker: this is exactly the path the sign-off
      # check exists for — a month can reach `reviewed` before a rule exists,
      # and signing is the act that makes the number final.
      invoices =
        Enum.map(reviewed.invoices, &Map.put(&1, "document", %{"credit_note" => true}))

      {:ok, reviewed} =
        reviewed
        |> Nila.Gst.Sales.Month.changeset(%{invoices: invoices})
        |> Nila.Repo.update()

      assert {:error, {:blocking_issues, ["credit_note_unsupported"]}} =
               Signoffs.sign_off_gstr1(reviewed, scope)

      assert {:error, :not_found} = Signoffs.latest_gstr1_signoff(reviewed.id)
    end

    test "a signed sales month is a wall for new decisions", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)
      {:ok, _} = Signoffs.sign_off_gstr1(reviewed, scope)

      assert {:error, :signed_off} =
               SalesResolutions.record(
                 reviewed,
                 %{"verb" => "reopen", "target" => "anything"},
                 scope.user.id
               )
    end

    test "3B assembles from the signed R1 snapshot, not a live derivation", %{
      month: client_month,
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)
      {:ok, signoff} = Signoffs.sign_off_gstr1(reviewed, scope)

      gstr3b = Nila.Gst.Purchase.Resolutions.workings(client_month).gstr3b
      assert gstr3b["liability_source"] == "gstr1_signed"

      expected = Nila.Gst.Filing.Gstr3b.liability_from_gstr1(signoff.snapshot["derived"])
      assert gstr3b["liability_31"]["a"]["txval"] == expected["txval"]
    end

    test "a signed GSTR-1 files independently of the 3B", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)

      assert {:error, :not_signed} = Signoffs.mark_filed(reviewed, scope, nil)

      {:ok, r1_signoff} = Signoffs.sign_off_gstr1(reviewed, scope)

      assert {:ok, filed} = Signoffs.mark_filed(reviewed, scope, nil)
      assert filed.state == "filed"
      assert filed.filed_at

      assert {:error, :filed} = Signoffs.reopen(r1_signoff, scope)
    end

    test "filing GSTR-1 makes only held sales dumps terminal", %{
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)
      assert {:ok, _} = Signoffs.sign_off_gstr1(reviewed, scope)

      sales = held_dump!(sales_month, scope.user.id, "sales")
      purchase = held_dump!(sales_month, scope.user.id, "purchase")

      assert {:ok, _} = Signoffs.mark_filed(reviewed, scope)

      assert {:ok, %{status: "after_filing"}} = Dumps.fetch(sales_month.org_id, sales.id)
      assert {:ok, %{status: "held"}} = Dumps.fetch(sales_month.org_id, purchase.id)
    end

    test "reopening the GSTR-1 cascades to the dependent 3B signature", %{
      month: client_month,
      sales_month: sales_month,
      owner_scope: scope
    } do
      reviewed = make_reviewed(sales_month, scope.user.id)
      {:ok, r1_signoff} = Signoffs.sign_off_gstr1(reviewed, scope)
      {:ok, _gstr3b_signoff} = Signoffs.sign_off(client_month, scope)

      assert {:ok, _} = Signoffs.reopen(r1_signoff, scope)

      assert {:error, :not_found} = Signoffs.latest_gstr1_signoff(sales_month.id)
      assert {:error, :not_found} = Signoffs.latest_signoff(client_month.id)

      {:ok, client_month} =
        ClientMonths.get_by_period(
          client_month.org_id,
          client_month.client_id,
          client_month.period
        )

      assert client_month.state == "worked"

      {:ok, sales_month} =
        SalesMonths.get_by_period(sales_month.org_id, sales_month.client_id, @period)

      assert {:ok, _} =
               SalesResolutions.record(
                 sales_month,
                 %{"verb" => "reopen", "target" => "anything"},
                 scope.user.id
               )
    end
  end
end
