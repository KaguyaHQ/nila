defmodule Nila.Gst.Purchase.ItcReviewBasis do
  @moduledoc "Binds an ITC review request to the case evidence and decision history shown."
  import Ecto.Query
  alias Nila.Gst.Purchase.{ItcCaseEvent, Reconciliation, Review}
  alias Nila.Repo

  def tokens(month, workings) do
    ids = Enum.map(workings.case_lines, & &1.case_id)
    pending = pending_case_ids(month, workings)

    versions =
      Repo.all(
        from e in ItcCaseEvent,
          where: e.case_id in ^ids,
          group_by: e.case_id,
          select: {e.case_id, max(e.id)}
      )
      |> Map.new()

    Map.new(workings.case_lines, fn line ->
      value =
        {1, month.org_id, month.client_id, month.period, line, workings.itc["blocks"],
         versions[line.case_id], MapSet.member?(pending, line.case_id)}

      token =
        value
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      {line.case_id, token}
    end)
  end

  def validate(_month, _workings, _ids, nil), do: :ok

  def validate(month, workings, ids, expected) when is_map(expected) do
    current = tokens(month, workings)

    cond do
      Enum.any?(ids, &(is_nil(current[&1]) or expected[to_string(&1)] != current[&1])) ->
        {:error, :stale}

      not MapSet.disjoint?(MapSet.new(ids), pending_case_ids(month, workings)) ->
        {:error, :pairing_pending}

      true ->
        :ok
    end
  end

  def validate(_, _, _, _), do: {:error, :stale}

  def pending_case_ids(month, workings) do
    items =
      Review.project(workings, month: month).all
      |> Enum.filter(&(&1.kind == :books and not &1.resolved and &1.candidates != []))

    books = items |> Enum.flat_map(& &1.member_ids) |> MapSet.new()
    portal = items |> Enum.flat_map(& &1.counterparts) |> MapSet.new(&Reconciliation.gstr2b_ref/1)

    workings.case_lines
    |> Enum.filter(fn line ->
      MapSet.member?(books, get_in(line.source_refs, ["books", month.period])) or
        MapSet.member?(portal, get_in(line.source_refs, ["gstr2b", month.period]))
    end)
    |> MapSet.new(& &1.case_id)
  end
end
