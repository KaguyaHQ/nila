defmodule Nila.Gst.Intake.PreconditionSweep do
  @moduledoc """
  Asks every already-extracted dump the questions it was never asked.

  `Nila.Gst.Intake.Preconditions` runs exactly once per dump, in
  `DumpWorker.do_perform/2`, between reading and deriving. That is the right
  place for it and the wrong number of times: a check that ships on Tuesday has
  never been put to anything that landed on Monday, and those dumps keep
  `status = "extracted"` — which is not "we asked and it was fine" but "nobody
  asked". The distinction is invisible in the column and load-bearing
  everywhere, because `Dumps.extracted_elsewhere/4` treats `"extracted"` as
  ground truth: `cross_month_duplicate` compares each new arrival against dumps
  that may themselves never have been vetted. One un-asked dump is therefore
  not inert. It is an oracle, and a correct packet can be refused by an
  incorrect one that got in first.

  This is the operator-invoked repair for that. It is deliberately not
  scheduled, not run on deploy, and not run at read time: re-asking is cheap
  only because the extraction is already paid for, and a sweep that fires by
  itself would re-open questions under a reviewer mid-decision.

  **Run it** after any new precondition check ships, and after resolving a
  cross-month duplicate — the surviving sibling still holds the finding that
  named the dump you just resolved, and nothing re-reads it. For a single dump,
  re-enqueueing its `DumpWorker` job does the same job: `do_perform/2` re-checks
  an `extracted` or `needs_confirmation` dump without re-extracting it.

      iex> Nila.Gst.Intake.PreconditionSweep.run(org_id)
      %{checked: 41, flagged: [8], skipped_wall: [], rederived: [{2, "2025-12"}]}

  Three properties worth stating, because each one is a decision:

    * **Every finding is computed before any dump is flipped.** Flipping a dump
      changes what `extracted_elsewhere/4` returns, so a sweep that mutated as
      it walked would let the first half of a duplicate pair silence the
      second — the packet that happened to be checked first would win on
      nothing but id order. Both halves are asked, from one snapshot, and both
      land in question. Which of the two is wrong is the reviewer's call and it
      is answerable from either month.
    * **A clean dump is not touched at all**, and its month is not re-derived.
      A sweep that rewrote every month it read would demote reviewed months
      across the org to `worked` for no finding.
    * **A signed or filed month is reported, never flipped.** Questioning a dump
      behind a signature strands it: the month cannot be rebuilt without a
      senior reopening, so the dump would sit in a state with no path out. What
      the sweep found is real and belongs in front of a person; acting on it
      silently is the part that isn't ours.
  """

  alias Nila.Gst.Intake.{Dump, DumpWorker, Dumps, Preconditions}
  alias Nila.Repo

  import Ecto.Query, only: [from: 2]

  @type summary :: %{
          checked: non_neg_integer(),
          flagged: [integer()],
          skipped_wall: [integer()],
          rederived: [{integer(), String.t()}]
        }

  @doc """
  Re-checks every extracted dump in `org_id` and returns what it did.

  `flagged` are the dumps now in `needs_confirmation`; `skipped_wall` are the
  ones whose finding stands but whose month is signed or filed, reported
  instead of flipped; `rederived` are the `{client_id, period}` pairs rebuilt
  from what survived. `checked` counts dumps examined, not dumps changed.

  Reviewer-answered dumps are left alone: `Preconditions.check/1` already
  short-circuits a `keep` answer, and the settled-question rule for
  `zero_overlap` lives there too. Neither is re-implemented here — a second
  copy of "has a human already ruled on this" is exactly how a question becomes
  a nag.
  """
  @spec run(integer()) :: summary()
  def run(org_id) do
    dumps = extracted(org_id)

    # One snapshot, taken whole, before anything moves.
    findings = for dump <- dumps, finding = Preconditions.check(dump), do: {dump, finding}

    {flagged, skipped} = Enum.split_with(findings, fn {dump, _} -> open?(dump) end)

    questioned = Enum.map(flagged, fn {dump, finding} -> ask(dump, finding) end)

    %{
      checked: length(dumps),
      flagged: Enum.map(questioned, & &1.id),
      skipped_wall: Enum.map(skipped, fn {dump, _finding} -> dump.id end),
      rederived: rederive_months(questioned)
    }
  end

  defp extracted(org_id) do
    Repo.all(
      from d in Dump,
        where: d.org_id == ^org_id and d.status == "extracted",
        order_by: [asc: d.id]
    )
  end

  defp open?(%Dump{} = dump), do: DumpWorker.wall_state(dump) == :open

  defp ask(%Dump{} = dump, finding), do: Dumps.mark_needs_confirmation(dump, finding)

  # A month is rebuilt once however many of its dumps left the effective set,
  # and each side of a client-month is its own row with its own union — so the
  # grouping is per side, and only the report collapses back to the pair the
  # caller reads. Any questioned dump of a group names the same
  # `(org, client, period)`, so the first one is as good a handle as any.
  defp rederive_months(questioned) do
    questioned
    |> Enum.group_by(&{&1.client_id, &1.period, side(&1)})
    |> Enum.map(fn {{client_id, period, _side}, [dump | _rest]} ->
      {:ok, _outcome} = DumpWorker.rederive(dump)
      {client_id, period}
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp side(%Dump{kind: kind}) when kind in ~w(sales filed_gstr1), do: :sales
  defp side(%Dump{}), do: :purchase
end
