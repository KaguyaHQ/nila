defmodule Nila.Gst.WorkQueue do
  @moduledoc """
  The front door's question: "what do I do right now?" Assembles one row per
  client-month the firm should be looking at today, each led by who it's
  waiting on.

  Row population: every client gets a row for the closeable period (the
  previous calendar month — June's returns file in July, so June is "the
  month" until August 1st), even when nothing has arrived yet — the clients
  who sent nothing are exactly the ones to chase. Older months stay on the
  list until both returns are filed; finished old months drop off. Fully
  filed closeable months show as done.

  Sections, in work order:

    * `:to_file` — a return is signed but not on the portal. The gap where a
      missed filing hides; it outranks everything.
    * `:needs_you` — open exceptions, or a sales month the maker hasn't
      finished. The junior reads this section top to bottom.
    * `:waiting_on_client` — documents missing and nothing workable yet.
      Chase verbs live here.
    * `:waiting_on_senior` — worked clean, awaiting signature.
    * `:waiting_on_portal` — the bills are in but the portal has not published
      the GSTR-2B yet. Nobody's move, so it sits below the sections that name
      a person.
    * `:done` — both returns filed.

  Within a section, nearest unmet deadline first.
  """

  alias Nila.Clients
  alias Nila.Orgs

  alias Nila.Gst.Chase
  alias Nila.Gst.Filing.{Calendar, Signoffs}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Purchase.{Register, Resolutions}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Months, as: SalesMonths

  @sections ~w(to_file needs_you waiting_on_client waiting_on_senior waiting_on_portal done)a

  def sections, do: @sections

  def section_title(:to_file), do: "Signed — file on the portal"
  def section_title(:needs_you), do: "Needs you"
  def section_title(:waiting_on_client), do: "Waiting on the client"
  def section_title(:waiting_on_senior), do: "Waiting on a senior"
  def section_title(:waiting_on_portal), do: "Waiting on the portal's GSTR-2B"
  def section_title(:done), do: "Done"

  @doc "The assembled rows for `org_id` as of `today`, sorted section-then-deadline."
  def rows(org_id, %Date{} = today) do
    closeable = Calendar.closeable_period(today)
    org = Orgs.get_org!(org_id)
    clients = Clients.list_clients(org_id)
    clients_by_id = Map.new(clients, &{&1.id, &1})

    months =
      Map.merge(
        Map.new(
          PurchaseMonths.list_for_org(org_id),
          &{{&1.client_id, &1.period}, %{purchase: &1}}
        ),
        Map.new(SalesMonths.list_for_org(org_id), &{{&1.client_id, &1.period}, %{sales: &1}}),
        fn _key, a, b -> Map.merge(a, b) end
      )

    keys =
      MapSet.union(
        MapSet.new(Map.keys(months)),
        MapSet.new(clients, &{&1.id, closeable})
      )

    processing_months =
      org_id
      |> Dumps.active_for_org()
      |> MapSet.new(&{&1.client_id, &1.period})

    gstr2b_months = Dumps.gstr2b_months(org_id)

    keys
    |> Enum.map(fn {client_id, period} = key ->
      row(
        org,
        clients_by_id[client_id],
        period,
        months[key] || %{},
        today,
        MapSet.member?(processing_months, key),
        MapSet.member?(gstr2b_months, key)
      )
    end)
    |> Enum.reject(&(&1.section == :done and &1.period != closeable))
    |> Enum.sort_by(&{section_rank(&1.section), &1.days_left || 999, &1.client_name})
  end

  defp row(org, client, period, months, today, processing?, gstr2b_in?) do
    purchase = months[:purchase]
    sales = months[:sales]

    need_decision = purchase_need_decision(purchase)
    sales_open = sales_open_issues(sales)

    r1_signed = sales != nil and match?({:ok, _}, Signoffs.latest_gstr1_signoff(sales.id))
    r1_filed = sales != nil and sales.filed_at != nil
    gstr3b_signed = purchase != nil and match?({:ok, _}, Signoffs.latest_signoff(purchase.id))
    gstr3b_filed = purchase != nil and purchase.filed_at != nil

    section =
      blocking_state(%{
        purchase: purchase,
        sales: sales,
        need_decision: need_decision,
        gstr2b_in: gstr2b_in?,
        gstr2b_available: Calendar.status(period, today).gstr2b_available?,
        r1_signed: r1_signed,
        r1_filed: r1_filed,
        gstr3b_signed: gstr3b_signed,
        gstr3b_filed: gstr3b_filed
      })

    deadline = deadline(period, today, r1_filed, gstr3b_filed)
    slots = %{purchase: purchase != nil, sales: sales != nil}
    asks = Chase.list_asks(client.org_id, client.id, period)

    %{
      org_id: client.org_id,
      client_id: client.id,
      client_name: client.name,
      chase_channel: client.chase_channel,
      period: period,
      section: section,
      deadline: deadline,
      days_left: deadline && deadline.days_left,
      invoices: purchase_invoices(purchase),
      need_decision: need_decision,
      sales_open: sales_open,
      slots: slots,
      processing?: processing?,
      last_ask_at: asks |> List.first() |> then(&(&1 && &1.inserted_at)),
      ask_count: length(asks),
      draft: build_draft(org, client, period, purchase, slots),
      path: row_path(client, period, purchase, sales)
    }
  end

  @doc """
  Per-return status for a client-month: `%{sales: status, purchase: status}`.

  A month is a *pair*, not a scalar. The two returns have independent
  lifecycles (GSTR-1 files on the 11th, GSTR-3B on the 20th), so any surface
  that collapses them to one word has to invent a precedence rule, and two
  surfaces inventing it separately is how the month page grew two doors out
  of one state. This is the single derivation; `blocking_state/1` folds it for
  Today, and the month workbench reads the pair directly.

  Statuses, in lifecycle order:

    * `:absent` — no month row yet; the documents haven't arrived.
    * `:awaiting_2b` — purchase only. The bills are in, but the portal has not
      published the GSTR-2B for this period yet. Nothing can be reconciled and
      nobody can act; this is the normal state of every client for the first
      two weeks of a filing month.
    * `:need_2b` — purchase only. The 2B has been published and nobody has
      brought it in. Live work, and it blocks every decision behind it.
    * `:open` — live work for the person on the page (decisions to make,
      issues to check, a draft the maker hasn't finished).
    * `:clear` — worked clean, waiting on a signature.
    * `:signed` — signed but not on the portal. The filing gap.
    * `:filed` — done.

  The two 2B statuses exist because `Reconciliation.reconcile/3` accepts an
  empty 2B side without complaint: every books invoice falls into
  `in_books_not_2b`, so `need_decision` counts the whole register and the page
  reads it as a pile of judgements. They are not judgements — there is nothing
  to judge against. Without this split the month page points a primary button
  at work that cannot be done correctly, and any answer given is guessing that
  the real 2B will contradict on the 14th.
  """
  def track_states(
        %{
          purchase: _,
          sales: _,
          need_decision: _,
          gstr2b_in: _,
          gstr2b_available: _,
          r1_signed: _,
          r1_filed: _,
          gstr3b_signed: _,
          gstr3b_filed: _
        } = facts
      ) do
    %{sales: sales_track(facts), purchase: purchase_track(facts)}
  end

  defp sales_track(%{sales: nil}), do: :absent
  defp sales_track(%{r1_filed: true}), do: :filed
  defp sales_track(%{r1_signed: true}), do: :signed
  defp sales_track(%{sales: %{state: "reviewed"}}), do: :clear
  defp sales_track(_facts), do: :open

  defp purchase_track(%{purchase: nil}), do: :absent
  defp purchase_track(%{gstr3b_filed: true}), do: :filed
  defp purchase_track(%{gstr3b_signed: true}), do: :signed
  defp purchase_track(%{gstr2b_in: false, gstr2b_available: false}), do: :awaiting_2b
  defp purchase_track(%{gstr2b_in: false}), do: :need_2b
  defp purchase_track(%{need_decision: need}) when need > 0, do: :open
  defp purchase_track(_facts), do: :clear

  @doc """
  Who a client-month is waiting on — the fold of `track_states/1` down to the
  one atom Today's sections need. Most urgent first: a signed-unfiled return
  outranks open work (filing is the step nobody may miss), so a month with
  open work on one side and a signature on the other belongs to the filing gap.
  """
  def blocking_state(input) when is_map(input), do: input |> track_states() |> fold_state()

  @doc """
  Folds a `track_states/1` pair to Today's single section atom.

  `:awaiting_2b` is the only status that names nobody, so it falls to the
  bottom: a section that says "waiting on the portal" must not outrank one
  that says "waiting on a person", or the junior's list leads with rows he
  cannot move.
  """
  def fold_state(%{sales: sales, purchase: purchase}) do
    tracks = [sales, purchase]

    cond do
      Enum.all?(tracks, &(&1 == :filed)) -> :done
      Enum.any?(tracks, &(&1 == :signed)) -> :to_file
      Enum.any?(tracks, &(&1 in [:open, :need_2b])) -> :needs_you
      Enum.any?(tracks, &(&1 == :absent)) -> :waiting_on_client
      Enum.any?(tracks, &(&1 == :clear)) -> :waiting_on_senior
      true -> :waiting_on_portal
    end
  end

  @doc """
  The nearest unmet return's clock: GSTR-1 until it's filed (due the 11th),
  then GSTR-3B (the 20th). Both filed — no clock (`nil`).
  """
  def deadline(period, today, r1_filed, gstr3b_filed) do
    status = Calendar.status(period, today)

    cond do
      not r1_filed ->
        %{return: "GSTR-1", days_left: status.gstr1_days_left, due: status.gstr1_due}

      not gstr3b_filed ->
        %{return: "GSTR-3B", days_left: status.gstr3b_days_left, due: status.gstr3b_due}

      true ->
        nil
    end
  end

  @doc """
  One track's clock, whichever return that track files.

  The month page's chip follows the track that owns its door: `deadline/4`
  always leads with GSTR-1 while it is unfiled, which is the wrong return to
  put in front of a reviewer working 3B decisions in the 3B window.

  There is no "already met" case to render. A filed return never owns the
  door, so its clock is never asked for, and the page simply stops mentioning
  it. What is deliberately *not* silenced is age: an old unfiled month keeps
  its alarm, because a client who never filed February is not history, they
  are late.
  """
  def track_deadline(period, %Date{} = today, track) when track in [:sales, :purchase] do
    status = Calendar.status(period, today)

    case track do
      :sales ->
        %{return: "GSTR-1", days_left: status.gstr1_days_left, due: status.gstr1_due}

      :purchase ->
        %{return: "GSTR-3B", days_left: status.gstr3b_days_left, due: status.gstr3b_due}
    end
  end

  defp purchase_need_decision(nil), do: 0

  defp purchase_need_decision(purchase) do
    purchase |> Resolutions.workings() |> then(&Register.need_decision(&1.summary))
  end

  defp purchase_invoices(nil), do: 0

  defp purchase_invoices(purchase), do: Register.stats(purchase.summary).invoices

  defp sales_open_issues(nil), do: 0
  defp sales_open_issues(%{invoices: []}), do: 0

  defp sales_open_issues(sales) do
    SalesResolutions.workings(sales).issues
    |> Enum.count(&(&1["status"] == "open" and &1["level"] != "info"))
  end

  # The right ask for where the month stands: dumps still missing -> the
  # opening nudge; dumps in but the engine found gaps -> the specific chase;
  # everything in and nothing missing -> nothing to ask.
  defp build_draft(org, client, period, purchase, slots) do
    cond do
      not (slots.purchase and slots.sales) ->
        %{kind: "month_open", body: Chase.draft(:month_open, org, client, period)}

      true ->
        case Chase.gaps(purchase) do
          %{in_2b_not_books: [], sequence_issues: []} ->
            nil

          gaps ->
            %{kind: "missing_bills", body: Chase.draft(:missing_bills, org, client, period, gaps)}
        end
    end
  end

  # Click follows the work: the month workbench when anything has arrived
  # (it renders whichever sides exist), the intake flow — pre-scoped to this
  # client-month — when nothing has.
  defp row_path(client, period, purchase, sales) do
    if purchase || sales,
      do: "/gst/#{client.id}/#{period}",
      else: "/gst/upload?client_id=#{client.id}&period=#{period}"
  end

  defp section_rank(section), do: Enum.find_index(@sections, &(&1 == section))
end
