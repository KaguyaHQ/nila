defmodule Nila.Gst.Today do
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
    * `:done` — both returns filed.

  Within a section, nearest unmet deadline first.
  """

  alias Nila.Clients
  alias Nila.Gst.{Calendar, Chase, ClientMonths, Resolutions, SalesMonths, SalesResolutions}
  alias Nila.Gst.Signoffs

  @sections ~w(to_file needs_you waiting_on_client waiting_on_senior done)a

  def sections, do: @sections

  def section_title(:to_file), do: "Signed — file on the portal"
  def section_title(:needs_you), do: "Needs you"
  def section_title(:waiting_on_client), do: "Waiting on the client"
  def section_title(:waiting_on_senior), do: "Waiting on a senior"
  def section_title(:done), do: "Done"

  @doc "The assembled rows for `org_id` as of `today`, sorted section-then-deadline."
  def rows(org_id, %Date{} = today) do
    closeable = Calendar.closeable_period(today)
    clients = Clients.list_clients(org_id)
    clients_by_id = Map.new(clients, &{&1.id, &1})

    months =
      Map.merge(
        Map.new(ClientMonths.list_for_org(org_id), &{{&1.client_id, &1.period}, %{purchase: &1}}),
        Map.new(SalesMonths.list_for_org(org_id), &{{&1.client_id, &1.period}, %{sales: &1}}),
        fn _key, a, b -> Map.merge(a, b) end
      )

    keys =
      MapSet.union(
        MapSet.new(Map.keys(months)),
        MapSet.new(clients, &{&1.id, closeable})
      )

    keys
    |> Enum.map(fn {client_id, period} = key ->
      row(clients_by_id[client_id], period, months[key] || %{}, today)
    end)
    |> Enum.reject(&(&1.section == :done and &1.period != closeable))
    |> Enum.sort_by(&{section_rank(&1.section), &1.days_left || 999, &1.client_name})
  end

  defp row(client, period, months, today) do
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
        r1_signed: r1_signed,
        r1_filed: r1_filed,
        gstr3b_signed: gstr3b_signed,
        gstr3b_filed: gstr3b_filed
      })

    deadline = deadline(period, today, r1_filed, gstr3b_filed)
    slots = %{purchase: purchase != nil, sales: sales != nil}

    %{
      client_id: client.id,
      client_name: client.name,
      period: period,
      section: section,
      deadline: deadline,
      days_left: deadline && deadline.days_left,
      invoices: purchase_invoices(purchase),
      need_decision: need_decision,
      sales_open: sales_open,
      slots: slots,
      last_ask_at: last_ask_at(client.org_id, client.id, period),
      draft: build_draft(client, period, purchase, slots),
      path: row_path(client, period, purchase, sales)
    }
  end

  @doc """
  Who a client-month is waiting on — the one derivation both Today's rows and
  the month workbench's state strip read, so they can never disagree. First
  match wins, most urgent first: a signed-unfiled return outranks open work
  (filing is the step nobody may miss); a row with open work on one side and
  a signed return on the other belongs to the filing gap.
  """
  def blocking_state(%{
        purchase: purchase,
        sales: sales,
        need_decision: need_decision,
        r1_signed: r1_signed,
        r1_filed: r1_filed,
        gstr3b_signed: gstr3b_signed,
        gstr3b_filed: gstr3b_filed
      }) do
    cond do
      r1_filed and gstr3b_filed ->
        :done

      (r1_signed and not r1_filed) or (gstr3b_signed and not gstr3b_filed) ->
        :to_file

      (purchase != nil and need_decision > 0) or (sales != nil and sales.state == "worked") ->
        :needs_you

      purchase == nil or sales == nil ->
        :waiting_on_client

      true ->
        :waiting_on_senior
    end
  end

  @doc """
  The nearest unmet return's clock: GSTR-1 until it's filed (due the 11th),
  then GSTR-3B (the 20th). Both filed — no clock (`nil`).
  """
  def deadline(period, today, r1_filed, gstr3b_filed) do
    status = Calendar.status(period, today)

    cond do
      not r1_filed -> %{return: "GSTR-1", days_left: status.gstr1_days_left}
      not gstr3b_filed -> %{return: "GSTR-3B", days_left: status.gstr3b_days_left}
      true -> nil
    end
  end

  defp purchase_need_decision(nil), do: 0

  defp purchase_need_decision(purchase) do
    buckets = Resolutions.workings(purchase).summary["buckets"] || %{}
    total = buckets |> Map.values() |> Enum.sum()
    total - (buckets["matched"] || 0)
  end

  defp purchase_invoices(nil), do: 0

  defp purchase_invoices(purchase) do
    (purchase.summary["buckets"] || %{}) |> Map.values() |> Enum.sum()
  end

  defp sales_open_issues(nil), do: 0
  defp sales_open_issues(%{invoices: []}), do: 0

  defp sales_open_issues(sales) do
    SalesResolutions.workings(sales).issues
    |> Enum.count(&(&1["status"] == "open" and &1["level"] != "info"))
  end

  defp last_ask_at(org_id, client_id, period) do
    case Chase.last_ask(org_id, client_id, period) do
      {:ok, ask} -> ask.inserted_at
      {:error, :not_found} -> nil
    end
  end

  # The right ask for where the month stands: dumps still missing -> the
  # opening nudge; dumps in but the engine found gaps -> the specific chase;
  # everything in and nothing missing -> nothing to ask.
  defp build_draft(client, period, purchase, slots) do
    cond do
      not (slots.purchase and slots.sales) ->
        %{kind: "month_open", body: Chase.draft(:month_open, client, period)}

      true ->
        case Chase.gaps(purchase) do
          %{in_2b_not_books: [], sequence_issues: []} ->
            nil

          gaps ->
            %{kind: "missing_bills", body: Chase.draft(:missing_bills, client, period, gaps)}
        end
    end
  end

  # Click follows the work: the month workbench when anything has arrived
  # (it renders whichever sides exist), the upload flow when nothing has.
  defp row_path(client, period, purchase, sales) do
    if purchase || sales,
      do: "/gst/#{client.id}/#{period}",
      else: "/gst/upload"
  end

  defp section_rank(section), do: Enum.find_index(@sections, &(&1 == section))
end
