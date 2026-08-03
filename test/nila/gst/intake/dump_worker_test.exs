defmodule Nila.Gst.Intake.DumpWorkerTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures
  import Nila.GstFixtures, only: [confirm_sales_complete!: 3, settle_register!: 2]

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.{DumpWorker, Dumps}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.Resolutions
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Workings, as: SalesWorkings
  alias Nila.Storage

  # The stub packet's bills are dated October 2025, and so is the 2B fixture
  # below. The period has to agree with them or intake's precondition check
  # (correctly) refuses to build the month — see `Nila.Gst.Intake.Preconditions`.
  @period "2025-10"

  setup do
    %{user: user, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    %{
      org: org,
      user: user,
      client: client,
      scope: %Scope{user: user, current_org: org, membership: membership}
    }
  end

  defp bring_in(org, client, user, kind, bytes) do
    key = "dumps/#{org.id}/#{client.id}/#{@period}/#{System.unique_integer([:positive])}"
    {:ok, _} = Storage.put(key, bytes)

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: @period, kind: kind, file_keys: [key]}
      )

    dump
  end

  defp run(dump), do: perform_job(DumpWorker, %{"dump_id" => dump.id})

  defp sign_sales(month, user, scope) do
    SalesResolutions.workings(month).issues
    |> Enum.filter(&(&1["status"] == "open" and &1["level"] != "info"))
    |> Enum.each(fn issue ->
      {:ok, _} =
        SalesResolutions.record(
          month,
          %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(issue)},
          user.id
        )
    end)

    {:ok, reviewed} = SalesResolutions.mark_reviewed(month)

    {:ok, client} = Clients.get_client(month.org_id, month.client_id)
    _confirmation = confirm_sales_complete!(scope.current_org, client, month.period)

    {:ok, signoff} = Signoffs.sign_off_gstr1(reviewed, scope)
    {reviewed, signoff}
  end

  test "a sales dump alone starts the month: extracted, derived, worked", %{
    org: org,
    user: user,
    client: client
  } do
    dump = bring_in(org, client, user, "sales", "%PDF-1.4 fake")

    assert :ok = run(dump)

    {:ok, dump} = Dumps.fetch(org.id, dump.id)
    assert dump.status == "extracted"
    assert length(dump.invoices) == 3

    source_ids = ["d#{dump.id}_inv_01", "d#{dump.id}_inv_02", "d#{dump.id}_inv_03"]
    assert Enum.map(dump.invoices, & &1["id"]) == source_ids

    assert :ok = run(dump)
    {:ok, recomputed} = Dumps.fetch(org.id, dump.id)
    assert Enum.map(recomputed.invoices, & &1["id"]) == source_ids

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"
    assert length(month.invoices) == 3
    assert month.derived_gstr1["gstin"] == "33AEWPH4158J1Z3"

    # Evidence is stored under the dump-namespaced basename carried on the invoice.
    basename = month.invoices |> hd() |> Map.fetch!("image")
    assert basename =~ "d#{dump.id}_"
    assert {:ok, bytes} = SalesMonths.fetch_evidence(org.id, client.id, @period, basename)
    assert byte_size(bytes) > 0
  end

  test "a purchase dump without 2B derives an honest bookside-only month", %{
    org: org,
    user: user,
    client: client
  } do
    dump = bring_in(org, client, user, "purchase", "%PDF-1.4 fake")

    assert :ok = run(dump)

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"

    buckets = month.summary["buckets"]
    assert buckets["in_books_not_2b"] >= 1
    assert (buckets["matched"] || 0) == 0
  end

  test "a 2B dump after the purchase dump re-reconciles; a second 2B replaces the first", %{
    org: org,
    user: user,
    client: client
  } do
    assert :ok = run(bring_in(org, client, user, "purchase", "%PDF-1.4 fake"))
    assert :ok = run(bring_in(org, client, user, "gstr2b", gstr2b_json()))

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.summary["buckets"]["matched"] >= 1
    assert month.summary["buckets"]["in_2b_not_books"] >= 1

    # A later, empty 2B replaces the first snapshot entirely.
    assert :ok = run(bring_in(org, client, user, "gstr2b", empty_gstr2b_json()))

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert (month.summary["buckets"]["matched"] || 0) == 0
    assert (month.summary["buckets"]["in_2b_not_books"] || 0) == 0
  end

  test "a straggler sales dump accretes and earlier resolutions survive", %{
    org: org,
    user: user,
    client: client
  } do
    assert :ok = run(bring_in(org, client, user, "sales", "%PDF-1.4 fake"))
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    poison =
      SalesResolutions.workings(month).issues
      |> Enum.find(&(&1["code"] == "grand_total_mismatch"))

    {:ok, _} =
      SalesResolutions.record(
        month,
        %{"verb" => "confirm_issue", "target" => SalesWorkings.issue_key(poison)},
        user.id
      )

    # The straggler doubles the invoice pile (stub returns the same 3 pages).
    assert :ok = run(bring_in(org, client, user, "sales", "%PDF-1.4 more"))

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert length(month.invoices) == 6

    replayed = SalesResolutions.workings(month)
    confirmed = Enum.find(replayed.issues, &(SalesWorkings.issue_key(&1) == poison["target"]))
    resolved = Enum.filter(replayed.issues, &(&1["status"] == "resolved"))

    assert confirmed == nil or confirmed["status"] == "resolved"
    assert resolved != []

    duplicate_groups = Enum.filter(replayed.issues, &(&1["code"] == "duplicate_invoice_number"))
    assert length(duplicate_groups) == 3
    assert Enum.all?(duplicate_groups, &(length(&1["source_ids"]) == 2))
    assert Enum.all?(duplicate_groups, &(length(Enum.uniq(&1["source_ids"])) == 2))
  end

  test "a sales dump on a signed GSTR-1 is held; release derives it in", %{
    org: org,
    user: user,
    client: client,
    scope: scope
  } do
    assert :ok = run(bring_in(org, client, user, "sales", "%PDF-1.4 fake"))
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)

    {_reviewed, signoff} = sign_sales(month, user, scope)

    straggler = bring_in(org, client, user, "sales", "%PDF-1.4 late")
    assert :ok = run(straggler)

    {:ok, straggler} = Dumps.fetch(org.id, straggler.id)
    assert straggler.status == "held"

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert length(month.invoices) == 3

    # Senior reopens; the released dump derives in.
    {:ok, _} = Signoffs.reopen(signoff, scope)
    released = Dumps.release(straggler)
    assert :ok = run(released)

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert length(month.invoices) == 6
    assert month.state == "worked"
  end

  test "a sales dump on a filed GSTR-1 is terminal and excluded from the union", %{
    org: org,
    user: user,
    client: client,
    scope: scope
  } do
    first = bring_in(org, client, user, "sales", "%PDF-1.4 fake")
    assert :ok = run(first)
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    {reviewed, _signoff} = sign_sales(month, user, scope)
    assert {:ok, _filed} = Signoffs.mark_filed(reviewed, scope)

    ClientMonths.subscribe(org.id)
    straggler = bring_in(org, client, user, "sales", "%PDF-1.4 late")
    assert :ok = run(straggler)

    assert_receive {:gst_dump_progress, straggler_id, client_id, @period, "sales", :after_filing}

    assert straggler_id == straggler.id
    assert client_id == client.id

    {:ok, straggler} = Dumps.fetch(org.id, straggler.id)
    assert straggler.status == "after_filing"
    assert Dumps.active(org.id, client.id, @period) == []
    assert Enum.map(Dumps.effective(org.id, client.id, @period, "sales"), & &1.id) == [first.id]
    assert_raise FunctionClauseError, fn -> Dumps.release(straggler) end

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert length(month.invoices) == 3
  end

  test "a purchase dump on a filed GSTR-3B is terminal and excluded from the union", %{
    org: org,
    user: user,
    client: client,
    scope: scope
  } do
    first = bring_in(org, client, user, "purchase", "%PDF-1.4 fake")
    assert :ok = run(first)
    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    confirm_sales_complete!(org, client, @period)
    month = settle_register!(month, scope.user.id)
    {:ok, _signoff} = Signoffs.sign_off(month, scope)
    assert {:ok, _filed} = Signoffs.mark_filed(month, scope)

    ClientMonths.subscribe(org.id)
    straggler = bring_in(org, client, user, "purchase", "%PDF-1.4 late")
    assert :ok = run(straggler)

    assert_receive {:gst_dump_progress, straggler_id, client_id, @period, "purchase",
                    :after_filing}

    assert straggler_id == straggler.id
    assert client_id == client.id

    {:ok, straggler} = Dumps.fetch(org.id, straggler.id)
    assert straggler.status == "after_filing"

    assert Enum.map(Dumps.effective(org.id, client.id, @period, "purchase"), & &1.id) == [
             first.id
           ]
  end

  test "purchase resolutions survive a 2B re-upload", %{
    org: org,
    user: user,
    client: client
  } do
    assert :ok = run(bring_in(org, client, user, "purchase", "%PDF-1.4 fake"))
    assert :ok = run(bring_in(org, client, user, "gstr2b", gstr2b_json()))

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    entry =
      Resolutions.workings(month).recon["needs_human"]
      |> Enum.find(&(length(&1["candidates"] || []) == 1))

    assert entry
    books_id = entry["books"]["id"]
    ref = entry["candidates"] |> hd() |> Nila.Gst.Purchase.Reconciliation.gstr2b_ref()

    {:ok, _} =
      Resolutions.record(
        month,
        %{"verb" => "confirm_pair", "books_id" => books_id, "gstr2b_ref" => ref},
        user.id
      )

    # Same 2B re-uploaded: recon rebuilds, decision replays — the ref is
    # content-derived, so the same 2B line carries the same ref.
    assert :ok = run(bring_in(org, client, user, "gstr2b", gstr2b_json()))

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    replayed = Resolutions.workings(month)
    row = Enum.find(replayed.rows, &(&1["id"] == books_id))
    assert row["bucket"] == "matched"
  end

  test "the same bill in two purchase dumps is flagged as a duplicate", %{
    org: org,
    user: user,
    client: client
  } do
    assert :ok = run(bring_in(org, client, user, "purchase", "%PDF-1.4 fake"))
    # The stub returns the same pages every time, so a re-sent folder is
    # exactly the cross-dump duplicate case.
    assert :ok = run(bring_in(org, client, user, "purchase", "%PDF-1.4 resent"))

    {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)

    duplicate_flags =
      month.register_rows
      |> Enum.flat_map(&(&1["flags"] || []))
      |> Enum.filter(&(&1["code"] == "duplicate_invoice"))

    assert duplicate_flags != []
  end

  test "a filed GSTR-1 lands on the month, survives re-derives, replaces on re-upload", %{
    org: org,
    user: user,
    client: client
  } do
    # The filed JSON can arrive first: the month starts as the comparison
    # target with no bills yet.
    assert :ok = run(bring_in(org, client, user, "filed_gstr1", filed_gstr1_json("v1")))

    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert month.invoices == []
    assert month.filed_gstr1["gstin"] == "33AEWPH4158J1Z3"
    assert month.filed_gstr1["marker"] == "v1"

    # Bills arriving later rebuild the month without dropping the filed return.
    assert :ok = run(bring_in(org, client, user, "sales", "%PDF-1.4 fake"))
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert length(month.invoices) == 3
    assert month.filed_gstr1["marker"] == "v1"

    # A re-upload replaces the snapshot — there is only ever one filed return.
    assert :ok = run(bring_in(org, client, user, "filed_gstr1", filed_gstr1_json("v2")))
    {:ok, month} = SalesMonths.get_by_period(org.id, client.id, @period)
    assert month.filed_gstr1["marker"] == "v2"
    assert length(month.invoices) == 3
  end

  test "a 2B declared as the filed GSTR-1 fails the shape check, not the month", %{
    org: org,
    user: user,
    client: client
  } do
    dump = bring_in(org, client, user, "filed_gstr1", gstr2b_json())

    assert {:error, :not_a_filed_gstr1} = run(dump)

    {:ok, dump} = Dumps.fetch(org.id, dump.id)
    assert dump.status == "failed"
    assert {:error, :not_found} = SalesMonths.get_by_period(org.id, client.id, @period)
  end

  test "a broken file marks the dump failed and the month untouched", %{
    org: org,
    user: user,
    client: client
  } do
    dump = bring_in(org, client, user, "gstr2b", "not json at all")

    assert {:error, _} = run(dump)

    {:ok, dump} = Dumps.fetch(org.id, dump.id)
    assert dump.status == "failed"
    assert dump.error

    assert {:error, :not_found} = ClientMonths.get_by_period(org.id, client.id, @period)
  end

  # A GSTR-2B that reconciles against the purchase stub's invoices: DPS-0072
  # matches exactly; INTER COOL's invoice number disagrees (→ needs_human);
  # an unknown vendor is 2B-only (→ in_2b_not_books).
  defp gstr2b_json do
    Jason.encode!(%{
      "data" => %{
        "docdata" => %{
          "b2b" => [
            supplier("32AAMFD7558A1ZL", "DAWN POWER SOLUTIONS", [
              invoice("DPS-0072", "08-10-2025", 20_060.0, 17_000.0, 3060.0)
            ]),
            supplier("32ACVPR7455F1Z3", "INTER COOL REFRIGERATION", [
              invoice("GX999", "12-10-2025", 949.99, 805.08, 144.91)
            ]),
            supplier("29AAACS9999A1Z5", "PHANTOM SUPPLIES", [
              invoice("PS-1", "05-10-2025", 5900.0, 5000.0, 900.0)
            ])
          ]
        }
      }
    })
  end

  defp empty_gstr2b_json do
    Jason.encode!(%{"data" => %{"docdata" => %{"b2b" => []}}})
  end

  # A minimal portal-shaped GSTR-1 download. `marker` proves which upload the
  # month currently holds.
  defp filed_gstr1_json(marker) do
    Jason.encode!(%{
      "gstin" => "33AEWPH4158J1Z3",
      "fp" => "102025",
      "marker" => marker,
      "b2b" => []
    })
  end

  defp supplier(ctin, trdnm, invoices),
    do: %{"ctin" => ctin, "trdnm" => trdnm, "inv" => invoices}

  defp invoice(inum, dt, val, txval, igst) do
    %{
      "inum" => inum,
      "dt" => dt,
      "val" => val,
      "pos" => "33",
      "rev" => "N",
      "itcavl" => "Y",
      "txval" => txval,
      "igst" => igst,
      "cgst" => 0,
      "sgst" => 0
    }
  end
end
