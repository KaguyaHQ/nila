defmodule Nila.Gst.Purchase.ItcDecisions do
  @moduledoc "Audited claim exclusions independent of document possession and matching."
  import Ecto.Query, only: [from: 2]
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.{Dump, DumpWorker}
  alias Nila.Gst.Purchase.{ItcAllocation, ItcCase, ItcCases, Month, Resolutions}
  alias Nila.Repo

  def exclude(scope, client_id, period, case_ids, reason) do
    if is_binary(reason) and String.trim(reason) != "" and String.length(reason) <= 1000 do
      record(scope, client_id, period, case_ids, "not_claiming_itc", %{
        "reason" => String.trim(reason)
      })
    else
      {:error, :reason_required}
    end
  end

  def reopen(scope, client_id, period, case_ids),
    do: record(scope, client_id, period, case_ids, "claim_reopened", %{})

  defp record(scope, client_id, period, case_ids, event_type, payload) do
    with true <- Policy.can?(scope, :edit_records),
         {:ok, ids} <- parse_ids(case_ids) do
      Repo.transact(fn ->
        month =
          Repo.one(
            from m in Month,
              where:
                m.org_id == ^scope.current_org.id and m.client_id == ^client_id and
                  m.period == ^period,
              lock: "FOR UPDATE"
          )

        with %Month{} <- month,
             :ok <- editable(month),
             :ok <- lock_cases(month, ids),
             lines = ItcCases.list_for_month(month),
             :ok <- validate_selection(lines, ids, event_type) do
          Enum.each(ids, fn id ->
            {:ok, _} = ItcCases.insert_event(month, id, event_type, scope.user.id, payload)
          end)

          workings = Resolutions.workings(month)

          month =
            month
            |> Month.changeset(%{register_rows: workings.rows, summary: workings.summary})
            |> Repo.update!()
            |> Repo.preload(:client)

          {:ok, %{month: month, workings: workings}}
        else
          nil -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      false -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp editable(month) do
    probe = %Dump{
      org_id: month.org_id,
      client_id: month.client_id,
      period: month.period,
      kind: "purchase"
    }

    if DumpWorker.wall_state(probe) == :open, do: :ok, else: {:error, :signed_off}
  end

  defp lock_cases(month, ids) do
    found =
      Repo.all(
        from c in ItcCase,
          where: c.id in ^ids and c.org_id == ^month.org_id and c.client_id == ^month.client_id,
          order_by: c.id,
          lock: "FOR UPDATE",
          select: c.id
      )

    allocated =
      Repo.exists?(from a in ItcAllocation, where: a.case_id in ^found and is_nil(a.revoked_at))

    cond do
      length(found) != length(ids) -> {:error, :invalid_selection}
      allocated -> {:error, :already_allocated}
      true -> :ok
    end
  end

  defp validate_selection(lines, ids, event_type) do
    by_id = Map.new(lines, &{&1.case_id, &1})

    if Enum.all?(ids, fn id ->
         case by_id[id] do
           nil ->
             false

           line ->
             line.document_type in ~w(invoice debit_note) and line.tax_paise > 0 and
               Enum.all?(line.tax_heads, fn {_head, value} -> value >= 0 end) and
               line.settlement_state != "excluded" and
               (event_type != "claim_reopened" or line.claim_state == "not_claiming")
         end
       end), do: :ok, else: {:error, :invalid_selection}
  end

  defp parse_ids(ids) when is_list(ids) and ids != [] and length(ids) <= 500 do
    parsed =
      Enum.map(ids, fn
        id when is_integer(id) and id > 0 ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {number, ""} when number > 0 -> number
            _ -> nil
          end

        _ ->
          nil
      end)

    if nil in parsed,
      do: {:error, :invalid_selection},
      else: {:ok, Enum.uniq(parsed) |> Enum.sort()}
  end

  defp parse_ids(_), do: {:error, :invalid_selection}
end
