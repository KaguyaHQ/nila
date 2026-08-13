defmodule Nila.Gst.Intake.PreconditionSweepTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures
  import Nila.GstFixtures, only: [settle_register!: 2]

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.{Dump, DumpWorker, Dumps, Preconditions, PreconditionSweep}
  alias Nila.Gst.Purchase.Months, as: ClientMonths
  alias Nila.Gst.Purchase.Register
  alias Nila.Repo
  alias Nila.Storage

  defmodule Packet do
    @behaviour Nila.Gst.Extraction.Purchase

    @impl true
    def extract(_bytes, _opts), do: {:ok, %{pages: Process.get(:packet, []), images: %{}}}
  end

  setup do
    previous = Application.get_env(:nila, :purchase_extractor)
    Application.put_env(:nila, :purchase_extractor, Packet)
    on_exit(fn -> Application.put_env(:nila, :purchase_extractor, previous) end)

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
  # Packet building — the same shape `PreconditionsTest` uses, because the sweep
  # has to read exactly what a real extraction left behind.
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

  defp bring_in(context, period, bills) do
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
        %{period: period, kind: "purchase", file_keys: [key]}
      )

    dump
  end

  defp run(dump), do: perform_job(DumpWorker, %{"dump_id" => dump.id})

  defp reload(context, dump) do
    {:ok, dump} = Dumps.fetch(context.org.id, dump.id)
    dump
  end

  defp month(context, period) do
    {:ok, month} = ClientMonths.get_by_period(context.org.id, context.client.id, period)
    month
  end

  defp april_bills(count) do
    for i <- 1..count, do: {"APR-#{i}", "#{rem(i, 28) + 1}/04/2026"}
  end

  defp june_bills(count) do
    for i <- 1..count, do: {"JUN-#{i}", "#{rem(i, 28) + 1}/06/2026"}
  end

  # A dump exactly as a pre-guard worker left it: read, derived into its month,
  # and never asked whether it answers to that month. This is the state the
  # sweep exists for, and the only way to reach it now is to undo the asking —
  # which is precisely what shipping a check later does to every older dump.
  defp as_if_never_asked(context, dump) do
    dump = reload(context, dump)
    assert dump.status == "needs_confirmation"

    {:ok, dump} =
      dump
      |> Dump.changeset(%{status: "extracted", meta: Map.delete(dump.meta, "precondition")})
      |> Repo.update()

    :ok = DumpWorker.settle(dump)
    reload(context, dump)
  end

  # ---------------------------------------------------------------------------
  # The repair
  # ---------------------------------------------------------------------------

  test "a dump nobody asked is asked, and its month rebuilt without it", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)
    dump = as_if_never_asked(context, dump)

    # It is in the month and the month is built on it.
    assert Register.stats(month(context, "2026-06").summary).invoices == 6

    assert %{checked: 1, flagged: [id], skipped_wall: [], rederived: [{client_id, "2026-06"}]} =
             PreconditionSweep.run(context.org.id)

    assert id == dump.id
    assert client_id == context.client.id

    dump = reload(context, dump)
    assert dump.status == "needs_confirmation"
    assert dump.meta["precondition"]["kind"] == "period_mismatch"
    assert dump.meta["precondition"]["modal_period"] == "2026-04"

    # The extraction stands — the sweep routes, it never edits.
    assert length(dump.invoices) == 6

    # And the month no longer holds what it is no longer allowed to derive.
    assert Register.stats(month(context, "2026-06").summary).invoices == 0
    assert Dumps.effective(context.org.id, context.client.id, "2026-06", "purchase") == []
  end

  test "a clean dump is untouched and its month is not demoted", context do
    dump = bring_in(context, "2026-06", june_bills(6))
    assert :ok = run(dump)
    assert reload(context, dump).status == "extracted"

    # A month a senior has already worked past `worked`. Re-deriving it for no
    # finding would silently walk that back.
    {:ok, reviewed} =
      context
      |> month("2026-06")
      |> Ecto.Changeset.change(%{state: "reviewed"})
      |> Repo.update()

    assert %{checked: 1, flagged: [], skipped_wall: [], rederived: []} =
             PreconditionSweep.run(context.org.id)

    assert reload(context, dump).status == "extracted"

    after_sweep = month(context, "2026-06")
    assert after_sweep.state == "reviewed"
    assert after_sweep.updated_at == reviewed.updated_at
  end

  test "a dump behind a signature is reported, never flipped", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)
    dump = as_if_never_asked(context, dump)

    {:ok, _signoff} =
      context
      |> month("2026-06")
      |> settle_register!(context.scope.user.id)
      |> Signoffs.sign_off(context.scope)

    assert %{checked: 1, flagged: [], skipped_wall: [id], rederived: []} =
             PreconditionSweep.run(context.org.id)

    assert id == dump.id

    # Stranding a questioned dump behind a signature has no path out, so the
    # finding goes in front of a person instead of into the column.
    dump = reload(context, dump)
    assert dump.status == "extracted"
    refute Map.has_key?(dump.meta, "precondition")
    assert Register.stats(month(context, "2026-06").summary).invoices == 6
  end

  test "a dump the reviewer already kept is left alone", context do
    dump = bring_in(context, "2026-06", april_bills(6))
    assert :ok = run(dump)

    {:ok, kept} =
      Preconditions.keep(reload(context, dump), "Availing these credits in June", context.user.id)

    assert :ok = run(kept)
    assert reload(context, kept).status == "extracted"

    assert %{checked: 1, flagged: [], skipped_wall: [], rederived: []} =
             PreconditionSweep.run(context.org.id)

    kept = reload(context, kept)
    assert kept.status == "extracted"
    assert kept.meta["precondition_answer"]["reason"] == "Availing these credits in June"
    refute Map.has_key?(kept.meta, "precondition")
    assert Register.stats(month(context, "2026-06").summary).invoices == 6
  end

  # The other half of the sweep: a finding names a sibling, and when the sibling
  # goes the finding is left standing on nothing. Only a re-check retires it,
  # and the re-check has to put the packet *back* — deriving the month while
  # leaving the dump questioned would report success over an emptied month.
  test "a re-checked dump whose question no longer stands rejoins its month", context do
    bills = april_bills(4)

    # The misfiled copy nobody asked about, and the correct packet it refuses.
    # `extracted` is what makes the first one an oracle: the second is told it
    # duplicates a dump that is itself in the wrong month.
    misfiled = bring_in(context, "2026-12", bills)
    assert :ok = run(misfiled)
    misfiled = as_if_never_asked(context, misfiled)

    correct = bring_in(context, "2026-04", bills)
    assert :ok = run(correct)

    assert reload(context, correct).meta["precondition"]["duplicate_of"] ==
             %{"period" => "2026-12", "count" => 4}

    assert %{flagged: [id]} = PreconditionSweep.run(context.org.id)
    assert id == misfiled.id

    # The finding on the correct packet now names a dump that has left the
    # effective set, and nothing re-reads it. A re-check is the only retirement.
    assert reload(context, correct).status == "needs_confirmation"

    assert :ok = run(reload(context, correct))

    correct = reload(context, correct)
    assert correct.status == "extracted"
    refute Map.has_key?(correct.meta, "precondition")

    # No answer is forged: nobody said the packet belongs here, the reason to
    # doubt it simply went away.
    refute Map.has_key?(correct.meta, "precondition_answer")

    assert Register.stats(month(context, "2026-04").summary).invoices == 4
  end

  # An answer covers the questions that were put to the reviewer, not every
  # question anyone will ever write. Otherwise the dumps a human touched — the
  # load-bearing ones — become the only dumps no later check can reach.
  test "a dump kept for one question is still asked a later one", context do
    bills = april_bills(4)

    kept = bring_in(context, "2026-06", bills)
    assert :ok = run(kept)

    # The only question that existed that day.
    assert reload(context, kept).meta["precondition"]["kinds"] == ["period_mismatch"]

    {:ok, kept} =
      Preconditions.keep(reload(context, kept), "Availing these credits in June", context.user.id)

    assert :ok = run(kept)
    assert reload(context, kept).status == "extracted"

    # A second copy of the same bills lands in April, and nobody vets it.
    twin = bring_in(context, "2026-04", bills)
    assert :ok = run(twin)
    _twin = as_if_never_asked(context, twin)

    assert %{flagged: flagged} = PreconditionSweep.run(context.org.id)
    assert kept.id in flagged

    kept = reload(context, kept)
    assert kept.status == "needs_confirmation"
    assert kept.meta["precondition"]["kind"] == "cross_month_duplicate"

    # The dates answer still stands. Only the question nobody asked is asked.
    assert kept.meta["precondition"]["kinds"] == ["cross_month_duplicate"]
    assert kept.meta["precondition_answer"]["reason"] == "Availing these credits in June"
  end

  # The fallback for an answer recorded before kinds were. Re-asking a dump
  # whose answer cannot be scoped would re-open a settled question rather than
  # close a gap, so silence stays wholesale where that is all we know.
  test "a keep answer with no recorded kinds still silences everything", context do
    bills = april_bills(4)

    kept = bring_in(context, "2026-06", bills)
    assert :ok = run(kept)

    {:ok, kept} =
      Preconditions.keep(reload(context, kept), "Availing these credits in June", context.user.id)

    {:ok, kept} =
      kept
      |> Dump.changeset(%{
        meta: update_in(kept.meta, ["precondition_answer"], &Map.delete(&1, "kinds"))
      })
      |> Repo.update()

    assert :ok = run(kept)

    twin = bring_in(context, "2026-04", bills)
    assert :ok = run(twin)
    _twin = as_if_never_asked(context, twin)

    assert %{flagged: flagged} = PreconditionSweep.run(context.org.id)
    refute kept.id in flagged
    assert reload(context, kept).status == "extracted"
  end

  test "both halves of a duplicate pair land in question, each month rebuilt once", context do
    bills = april_bills(4)

    april = bring_in(context, "2026-04", bills)
    assert :ok = run(april)
    assert reload(context, april).status == "extracted"

    may = bring_in(context, "2026-05", bills)
    assert :ok = run(may)
    may = as_if_never_asked(context, may)

    assert %{checked: 2, flagged: flagged, skipped_wall: [], rederived: rederived} =
             PreconditionSweep.run(context.org.id)

    # Neither copy gets to win on id order: the question is which of the two is
    # in the wrong month, and it has to be answerable from either one.
    assert Enum.sort(flagged) == Enum.sort([april.id, may.id])

    assert rederived == [{context.client.id, "2026-04"}, {context.client.id, "2026-05"}]

    assert reload(context, april).meta["precondition"]["duplicate_of"] ==
             %{"period" => "2026-05", "count" => 4}

    assert reload(context, may).meta["precondition"]["duplicate_of"] ==
             %{"period" => "2026-04", "count" => 4}

    assert Register.stats(month(context, "2026-04").summary).invoices == 0
    assert Register.stats(month(context, "2026-05").summary).invoices == 0
  end
end
