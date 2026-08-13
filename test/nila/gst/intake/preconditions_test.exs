defmodule Nila.Gst.Intake.PreconditionsTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures
  import Nila.GstFixtures, only: [settle_register!: 2]

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.{DumpWorker, Dumps, Preconditions}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Storage

  # A purchase extractor the test hands its own packet to. Deliberately exports
  # no `provider/0` — an unaudited extractor skips the attempt plumbing, which
  # is not what these tests are about.
  defmodule Packet do
    @behaviour Nila.Gst.Extraction.Purchase

    @impl true
    def extract(_bytes, _opts), do: {:ok, %{pages: Process.get(:packet, []), images: %{}}}
  end

  defmodule SalesPacket do
    @behaviour Nila.Gst.Extraction.Sales

    @impl true
    def extract(_bytes, _opts), do: {:ok, %{pages: Process.get(:packet, []), images: %{}}}
  end

  setup do
    previous = Application.get_env(:nila, :purchase_extractor)
    previous_sales = Application.get_env(:nila, :sales_extractor)
    Application.put_env(:nila, :purchase_extractor, Packet)
    Application.put_env(:nila, :sales_extractor, SalesPacket)

    on_exit(fn ->
      Application.put_env(:nila, :purchase_extractor, previous)
      Application.put_env(:nila, :sales_extractor, previous_sales)
    end)

    %{user: user, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Caltech",
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

  # ---------------------------------------------------------------------------
  # Packet building
  # ---------------------------------------------------------------------------

  defp page(index, {number, date}) do
    %{
      "page" => index,
      "source_pages" => [index],
      "source_attribution" => %{"status" => "verified", "candidate_pages" => [index]},
      "image" => nil,
      "confidence" => nil,
      "data" => %{
        "is_invoice" => true,
        "continuation_of_previous" => false,
        "invoice_number" => number,
        "invoice_date" => date,
        "seller" => %{"name" => "DAWN POWER SOLUTIONS", "gstin" => "32AAMFD7558A1ZL"},
        "buyer" => %{"name" => "CALTECH", "gstin" => "33AEWPH4158J1Z3"},
        "line_items" => [
          %{
            "description" => "PARTS",
            "hsn_sac" => "8507",
            "quantity" => 1.0,
            "taxable_value" => 10_000.00,
            "igst_rate" => 18.0,
            "igst_amount" => 1800.00
          }
        ],
        "printed_grand_total" => 11_800.00
      }
    }
  end

  defp bring_in(context, period, bills, kind \\ "purchase") do
    Process.put(:packet, bills |> Enum.with_index(1) |> Enum.map(fn {b, i} -> page(i, b) end))

    key = "dumps/#{context.org.id}/#{period}/#{System.unique_integer([:positive])}"
    {:ok, _} = Storage.put(key, "%PDF-1.4 fake")

    {:ok, dump} =
      Dumps.record(
        %{
          org_id: context.org.id,
          client_id: context.client.id,
          brought_in_by_id: context.user.id
        },
        %{period: period, kind: kind, file_keys: [key]}
      )

    dump
  end

  defp run(dump), do: perform_job(DumpWorker, %{"dump_id" => dump.id})

  defp reload(context, dump) do
    {:ok, dump} = Dumps.fetch(context.org.id, dump.id)
    dump
  end

  defp april_bills(count) do
    for i <- 1..count, do: {"APR-#{i}", "#{rem(i, 28) + 1}/04/2026"}
  end

  # ---------------------------------------------------------------------------
  # a. Dates outside the period — the question
  # ---------------------------------------------------------------------------

  test "a packet dated January–April filed under June asks instead of deriving", context do
    bills =
      [{"JAN-1", "12/01/2026"}, {"FEB-1", "09/02/2026"}, {"MAR-1", "21/03/2026"}] ++
        april_bills(11)

    dump = bring_in(context, "2026-06", bills)
    assert :ok = run(dump)

    dump = reload(context, dump)
    assert dump.status == "needs_confirmation"

    finding = dump.meta["precondition"]
    assert finding["kind"] == "period_mismatch"
    assert finding["modal_period"] == "2026-04"
    assert finding["outside_period"] == 14
    assert finding["total"] == 14
    assert finding["outside_periods"] == ["2026-01", "2026-02", "2026-03", "2026-04"]

    # Extracted and stored — and the month is not built from it.
    assert length(dump.invoices) == 14

    assert {:error, :not_found} =
             ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")

    assert Dumps.effective(context.org.id, context.client.id, "2026-06", "purchase") == []
  end

  test "one straggler from last month does not trip the check", context do
    bills = [{"MAY-1", "28/05/2026"} | for(i <- 1..13, do: {"JUN-#{i}", "#{i}/06/2026"})]

    dump = bring_in(context, "2026-06", bills)
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"
    assert {:ok, month} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")
    assert month.state == "worked"
  end

  test "a two-bill packet, both old, is under the floor and derives", context do
    dump = bring_in(context, "2026-06", [{"MAY-1", "02/05/2026"}, {"MAY-2", "03/05/2026"}])
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"

    assert {:ok, _month} =
             ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")
  end

  # ---------------------------------------------------------------------------
  # b. The same bill in two months — the error
  # ---------------------------------------------------------------------------

  test "a packet already booked in April is caught, whatever its dates", context do
    bills = april_bills(4)

    assert :ok = run(bring_in(context, "2026-04", bills))

    # Same bills, same numbers and dates, into a month they are dated for: the
    # date check cannot see this one, and it is the one that double-claims.
    resent = bring_in(context, "2026-05", bills)
    assert :ok = run(resent)

    resent = reload(context, resent)
    assert resent.status == "needs_confirmation"

    finding = resent.meta["precondition"]
    assert finding["kind"] == "cross_month_duplicate"
    assert finding["duplicate_of"] == %{"period" => "2026-04", "count" => 4}

    # April is worked, not filed. Nothing has been declared twice, so the packet
    # is asked which month it belongs to — not told it broke the law.
    assert finding["severity"] == "question"
  end

  test "the same packet against a filed month is an error", context do
    bills = april_bills(4)

    assert :ok = run(bring_in(context, "2026-04", bills))
    {:ok, april} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-04")
    april = settle_register!(april, context.scope.user.id)
    {:ok, _signoff} = Signoffs.sign_off(april, context.scope)
    {:ok, _filed} = Signoffs.mark_filed(april, context.scope)

    resent = bring_in(context, "2026-05", bills)
    assert :ok = run(resent)

    finding = reload(context, resent).meta["precondition"]
    assert finding["kind"] == "cross_month_duplicate"

    # The credit went out on a return. This is the reading that makes the grade
    # true, and it is the only one that does.
    assert finding["severity"] == "error"
  end

  test "the same bill number under another client is not a duplicate", context do
    {:ok, other} =
      Clients.create_client(%{
        org_id: context.org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "27AAPFU0939F1ZV"
      })

    bills = april_bills(4)
    assert :ok = run(bring_in(context, "2026-04", bills))

    dump = bring_in(%{context | client: other}, "2026-05", bills)
    assert :ok = run(dump)

    # Dates still put it outside May, so the month asks — but never for a
    # duplicate: two clients legitimately hold the same vendor's bill number.
    dump = reload(context, dump)
    assert dump.meta["precondition"]["kind"] == "period_mismatch"
    refute Map.has_key?(dump.meta["precondition"], "duplicate_of")
  end

  # ---------------------------------------------------------------------------
  # c. Two populated sides with nothing in common
  # ---------------------------------------------------------------------------

  test "books and 2B both populated with nothing matched asks the question", context do
    assert :ok = run(bring_in(context, "2026-04", april_bills(4)))

    dump = bring_in(context, "2026-04", [], "gstr2b")
    Storage.put(hd(dump.file_keys), gstr2b_json(["OTHER-1", "OTHER-2"]))
    assert :ok = run(dump)

    dump = reload(context, dump)
    assert dump.status == "needs_confirmation"

    finding = dump.meta["precondition"]
    assert finding["kind"] == "zero_overlap"
    assert finding["observed"] == %{"books" => 4, "gstr2b" => 2, "matched" => 0}
  end

  test "one match is enough — the check is strictly zero", context do
    assert :ok = run(bring_in(context, "2026-04", april_bills(4)))

    dump = bring_in(context, "2026-04", [], "gstr2b")
    Storage.put(hd(dump.file_keys), gstr2b_json(["APR-1", "OTHER-2"]))
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"
    {:ok, month} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-04")
    assert month.summary["buckets"]["matched"] == 1
  end

  test "a full books side with no 2B yet is an ordinary month, not a question", context do
    dump = bring_in(context, "2026-04", april_bills(4))
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"

    assert {:ok, _month} =
             ClientMonths.get_by_period(context.org.id, context.client.id, "2026-04")
  end

  test "a 2B with no bills in yet is an ordinary month, not a question", context do
    dump = bring_in(context, "2026-04", [], "gstr2b")
    Storage.put(hd(dump.file_keys), gstr2b_json(["OTHER-1"]))
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"
  end

  # ---------------------------------------------------------------------------
  # The three answers
  # ---------------------------------------------------------------------------

  test "moving the packet repoints it and derives the destination", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)
    assert reload(context, dump).status == "needs_confirmation"

    {:ok, moved} = Preconditions.move(reload(context, dump), "2026-04", context.user.id)
    assert :ok = run(moved)

    moved = reload(context, moved)
    assert moved.period == "2026-04"
    assert moved.status == "extracted"

    # June never had a month built from it; April now does.
    assert {:error, :not_found} =
             ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")

    assert {:ok, april} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-04")
    assert Nila.Gst.Purchase.Register.stats(april.summary).invoices == 6
  end

  test "moving into a signed month lands held, the already-built outcome", context do
    assert :ok = run(bring_in(context, "2026-04", april_bills(4)))
    {:ok, april} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-04")
    april = settle_register!(april, context.scope.user.id)
    {:ok, _signoff} = Signoffs.sign_off(april, context.scope)

    dump =
      bring_in(context, "2026-06", [
        {"LATE-1", "05/04/2026"},
        {"LATE-2", "06/04/2026"},
        {"LATE-3", "07/04/2026"}
      ])

    assert :ok = run(dump)

    {:ok, moved} = Preconditions.move(reload(context, dump), "2026-04", context.user.id)
    assert :ok = run(moved)

    assert reload(context, moved).status == "held"
  end

  test "keeping the packet derives it and records why", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)

    {:ok, kept} =
      Preconditions.keep(reload(context, dump), "Availing these credits in June", context.user.id)

    assert :ok = run(kept)

    kept = reload(context, kept)
    assert kept.status == "extracted"
    assert kept.meta["precondition_answer"]["reason"] == "Availing these credits in June"
    assert kept.meta["precondition_answer"]["answered_by_id"] == context.user.id
    refute Map.has_key?(kept.meta, "precondition")

    assert {:ok, month} = ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")
    assert Nila.Gst.Purchase.Register.stats(month.summary).invoices == 6
  end

  test "a kept packet is not asked again", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)
    {:ok, kept} = Preconditions.keep(reload(context, dump), "Late bills", context.user.id)

    assert :ok = run(kept)
    assert :ok = run(reload(context, kept))
    assert reload(context, kept).status == "extracted"
  end

  test "keeping without a reason is refused", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)

    assert {:error, :reason_required} =
             Preconditions.keep(reload(context, dump), "   ", context.user.id)
  end

  test "discarding is terminal and builds nothing", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)

    {:ok, discarded} = Preconditions.discard(reload(context, dump), context.user.id)
    assert discarded.status == "discarded"
    assert discarded.meta["precondition_answer"]["answer"] == "discard"

    assert Dumps.effective(context.org.id, context.client.id, "2026-06", "purchase") == []

    assert {:error, :not_found} =
             ClientMonths.get_by_period(context.org.id, context.client.id, "2026-06")
  end

  test "answers are refused on a dump that is not in question", context do
    dump = bring_in(context, "2026-04", april_bills(4))
    assert :ok = run(dump)

    assert {:error, :not_in_question} = Preconditions.keep(reload(context, dump), "why", 1)
    assert {:error, :not_in_question} = Preconditions.discard(reload(context, dump), 1)
    assert {:error, :not_in_question} = Preconditions.move(reload(context, dump), "2026-05", 1)
  end

  # ---------------------------------------------------------------------------
  # Sales — the same two packet checks, read from the other side of the ledger
  # ---------------------------------------------------------------------------

  test "a sales packet dated June filed under December asks before drafting a return",
       context do
    bills = for i <- 1..8, do: {"#{i}/2026-27", "#{i}/06/2026"}

    dump = bring_in(context, "2025-12", bills, "sales")
    assert :ok = run(dump)

    dump = reload(context, dump)
    assert dump.status == "needs_confirmation"

    finding = dump.meta["precondition"]
    assert finding["kind"] == "period_mismatch"
    assert finding["modal_period"] == "2026-06"
    assert finding["outside_period"] == 8

    # The return is the thing this protects: nothing outward is built from it.
    assert Dumps.effective(context.org.id, context.client.id, "2025-12", "sales") == []
  end

  test "the same sales invoice declared in two months is an error", context do
    invoices = for i <- 1..4, do: {"#{i}/2026-27", "0#{i}/04/2026"}

    assert :ok = run(bring_in(context, "2026-04", invoices, "sales"))

    resent = bring_in(context, "2026-05", invoices, "sales")
    assert :ok = run(resent)

    resent = reload(context, resent)
    assert resent.status == "needs_confirmation"
    assert resent.meta["precondition"]["kind"] == "cross_month_duplicate"
    assert resent.meta["precondition"]["duplicate_of"] == %{"period" => "2026-04", "count" => 4}
  end

  # Sales has no second side to reconcile against, so the pairing check must not
  # reach across and fire on the purchase month that happens to share the period.
  test "a sales packet is never asked the overlap question", context do
    assert :ok = run(bring_in(context, "2026-04", april_bills(4)))

    dump = bring_in(context, "2026-04", [{"1/2026-27", "05/04/2026"}], "sales")
    assert :ok = run(dump)

    assert reload(context, dump).status == "extracted"
  end

  # The guard is scoped by kind, so its coverage has to be checked by kind. A
  # fourth kind added to the schema without a clause fails here rather than in a
  # worker, which is the whole reason `check/1` has no catch-all. Each dump
  # carries an in-period invoice so the checks actually run: an empty packet
  # returns nil from every check before reaching any of them, which would pass
  # just as well for a kind whose clause did nothing at all.
  test "every kind a dump can be is answered by check/1, and runs its checks", context do
    # A period each, so one kind's stored packet is not the other kind's finding
    # — a 2B lands beside the purchase books and the pair is checked for real.
    for {kind, period} <- Enum.zip(Nila.Gst.Intake.Dump.kinds(), ~w(2026-01 2026-02 2026-03)) do
      dump = bring_in(context, period, [], kind)

      dump =
        Dumps.mark_extracted(dump, [stored_invoice("A-1", Date.from_iso8601!(period <> "-08"))])

      assert Preconditions.check(dump) == nil, "#{kind} was not handled"
    end
  end

  # ---------------------------------------------------------------------------
  # What the checks can and cannot see
  # ---------------------------------------------------------------------------

  # Sales invoices extracted before dates were parsed at the boundary are stored
  # as the model printed them. A guard that only read ISO was blind to exactly
  # the history it exists to compare a new packet against.
  test "a packet stored with printed dates is still read", context do
    dump = bring_in(context, "2025-12", [], "sales")

    dump =
      Dumps.mark_extracted(dump, [
        stored_invoice("1/2026-27", "05.06.2026"),
        stored_invoice("2/2026-27", "06.06.2026"),
        stored_invoice("3/2026-27", "09.06.2026"),
        stored_invoice("4/2026-27", "11.06.2026")
      ])

    assert %{"kind" => "period_mismatch", "modal_period" => "2026-06"} =
             Preconditions.check(dump)
  end

  # A date nothing can read says nothing either way. It must not be counted as
  # in-period (which would vote against asking) and must not crash the check.
  test "dates nothing can read neither trip the check nor silence it", context do
    dump = bring_in(context, "2025-12", [], "sales")

    unreadable =
      for i <- 1..4, do: stored_invoice("X-#{i}", "Invoice Dt.")

    assert Preconditions.check(Dumps.mark_extracted(dump, unreadable)) == nil

    # Four June invoices behind four unreadable rows is still four invoices in
    # the wrong month: the majority is taken over what could be dated.
    june = for i <- 1..4, do: stored_invoice("JUN-#{i}", "0#{i}.06.2026")

    assert %{"kind" => "period_mismatch"} =
             Preconditions.check(Dumps.mark_extracted(dump, unreadable ++ june))
  end

  # Sales maps every page through normalization, cover sheets included, so the
  # denominator has to be the invoices that carry a date rather than the rows.
  test "undated pages do not dilute the majority", context do
    dump = bring_in(context, "2025-12", [], "sales")

    furniture = for i <- 1..9, do: %{"invoice_number" => "PAGE-#{i}", "invoice_date" => nil}
    june = for i <- 1..3, do: stored_invoice("JUN-#{i}", "0#{i}.06.2026")

    assert %{"kind" => "period_mismatch", "outside_period" => 3} =
             Preconditions.check(Dumps.mark_extracted(dump, furniture ++ june))
  end

  test "moving a sales packet carries its scans to the destination month", context do
    dump = bring_in(context, "2025-12", [], "sales")
    basename = "d#{dump.id}_page_01.png"

    Storage.put(
      SalesMonths.evidence_key(context.org.id, context.client.id, "2025-12", basename),
      "PNG"
    )

    dump =
      dump
      |> Dumps.mark_extracted([
        Map.put(stored_invoice("1/2026-27", ~D[2026-06-05]), "image", basename)
      ])
      |> Dumps.mark_needs_confirmation(%{"kind" => "period_mismatch"})

    {:ok, moved} = Preconditions.move(dump, "2026-06", context.user.id)
    assert moved.period == "2026-06"

    # Read through storage rather than `fetch_evidence/4`: the destination month
    # is derived by the worker afterwards, and the scans must already be there
    # when it is.
    assert {:ok, "PNG"} =
             Storage.get(
               SalesMonths.evidence_key(context.org.id, context.client.id, "2026-06", basename)
             )
  end

  defp stored_invoice(number, date) do
    %{
      "invoice_number" => number,
      "invoice_date" => date,
      "line_items" => [],
      "taxable_paise" => 10_000,
      "tax_paise" => %{"igst" => 1800},
      "total_paise" => 11_800
    }
  end

  defp gstr2b_json(numbers) do
    Jason.encode!(%{
      "data" => %{
        "docdata" => %{
          "b2b" => [
            %{
              "ctin" => "32AAMFD7558A1ZL",
              "trdnm" => "DAWN POWER SOLUTIONS",
              "inv" =>
                Enum.map(numbers, fn number ->
                  %{
                    "inum" => number,
                    "dt" => "02-04-2026",
                    "val" => 11_800.0,
                    "pos" => "33",
                    "rev" => "N",
                    "itcavl" => "Y",
                    "txval" => 10_000.0,
                    "igst" => 1800.0,
                    "cgst" => 0,
                    "sgst" => 0
                  }
                end)
            }
          ]
        }
      }
    })
  end
end
