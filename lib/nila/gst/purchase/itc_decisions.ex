defmodule Nila.Gst.Purchase.ItcDecisions do
  @moduledoc "Audited monthly treatment of outstanding input tax credit."
  import Ecto.Query, only: [from: 2]
  alias Nila.Accounts.Policy
  alias Nila.Gst.Intake.{Dump, DumpWorker}

  alias Nila.Gst.Purchase.{
    ItcAllocation,
    ItcCase,
    ItcCaseEvent,
    ItcCases,
    ItcTreatment,
    Month,
    Resolutions
  }

  alias Nila.Repo
  defdelegate reasons(kind), to: ItcTreatment

  def apply(scope, client_id, period, case_ids, attrs),
    do: record(scope, client_id, period, case_ids, attrs, :treatment)

  def record_document(scope, client_id, period, case_id),
    do: record(scope, client_id, period, [case_id], %{}, :document)

  defp record(scope, client_id, period, case_ids, attrs, action) do
    with true <- Policy.can?(scope, :edit_records),
         true <- is_binary(period) and Regex.match?(~r/\A\d{4}-(0[1-9]|1[0-2])\z/, period),
         {:ok, ids} <- parse_ids(case_ids) do
      Repo.transact(fn ->
        client =
          Repo.one(
            from c in Nila.Clients.Client,
              where: c.id == ^client_id and c.org_id == ^scope.current_org.id,
              lock: "FOR UPDATE"
          )

        with %Nila.Clients.Client{} <- client do
          month =
            Repo.one(
              from m in Month,
                where:
                  m.org_id == ^scope.current_org.id and m.client_id == ^client_id and
                    m.period == ^period,
                lock: "FOR UPDATE"
            ) ||
              %Month{org_id: scope.current_org.id, client_id: client_id}
              |> Month.changeset(%{period: period})
              |> Repo.insert!()

          with :ok <- editable(month),
               :ok <- lock_cases(month, ids),
               :ok <- ItcCases.refuse_later_signed_treatment(month, ids),
               workings = Resolutions.workings(month),
               {:ok, payloads} <- validate_action(workings, ids, attrs, action) do
            Enum.each(payloads, fn {id, payload} ->
              {:ok, _} =
                ItcCases.insert_event(
                  month,
                  id,
                  if(action == :document, do: "client_holds_document", else: "treatment_decided"),
                  scope.user.id,
                  payload
                )
            end)

            workings = Resolutions.workings(month)

            month =
              month
              |> Month.changeset(%{register_rows: workings.rows, summary: workings.summary})
              |> Repo.update!()
              |> Repo.preload(:client)

            {:ok, %{month: month, workings: workings}}
          end
        else
          nil -> {:error, :not_found}
        end
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp editable(month) do
    probe = %Dump{
      org_id: month.org_id,
      client_id: month.client_id,
      period: month.period,
      kind: "purchase"
    }

    if is_nil(month.filed_at) and DumpWorker.wall_state(probe) == :open,
      do: :ok,
      else: {:error, :signed_off}
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

    later =
      Repo.exists?(
        from e in ItcCaseEvent,
          join: m in assoc(e, :effective_client_month),
          where:
            e.case_id in ^found and e.event_type == "treatment_decided" and
              m.period > ^month.period
      )

    allocated =
      Repo.exists?(
        from a in ItcAllocation,
          join: m in assoc(a, :client_month),
          where: a.case_id in ^found and is_nil(a.revoked_at) and m.period >= ^month.period
      )

    cond do
      length(found) != length(ids) -> {:error, :invalid_selection}
      later -> {:error, :later_treatment_exists}
      allocated -> {:error, :already_allocated}
      true -> :ok
    end
  end

  defp validate_action(workings, ids, attrs, :treatment), do: validate(workings, ids, attrs)

  defp validate_action(workings, ids, _, :document) do
    lines = Enum.filter(workings.case_lines, &(&1.case_id in ids))

    if length(lines) == length(ids) and
         Enum.all?(
           lines,
           &(&1.has_gstr2b? and not &1.has_books? and &1.document_state != "held" and
               &1.document_type in ~w(invoice debit_note))
         ) do
      {:ok,
       Enum.map(
         lines,
         &{&1.case_id, %{"source_refs" => &1.source_refs, "tax_heads" => &1.tax_heads}}
       )}
    else
      {:error, :invalid_selection}
    end
  end

  defp validate(workings, ids, attrs) do
    by_id = Map.new(workings.case_lines, &{&1.case_id, &1})

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      line = by_id[id]

      with true <-
             line != nil and line.document_type in ~w(invoice debit_note) and
               line.settlement_state != "excluded" and ItcTreatment.valid?(line.outstanding_heads) and
               ItcTreatment.sum(line.outstanding_heads) > 0,
           {:ok, payload} <- ItcTreatment.build(line.outstanding_heads, attrs),
           :ok <- Nila.Gst.Cess.validate_treatment(payload),
           :ok <- guard_claim(line, payload, workings.itc["blocks"] || []) do
        {:cont,
         {:ok,
          [
            {id,
             payload
             |> Map.put("source_refs", line.source_refs)
             |> Map.put("source_heads", line.tax_heads)}
            | acc
          ]}}
      else
        false -> {:halt, {:error, :invalid_selection}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp guard_claim(line, payload, blocks) do
    blocked = Enum.any?(blocks, &ItcCases.block_applies?(&1, line))

    cond do
      ItcTreatment.sum(payload["claim"]) == 0 -> :ok
      not line.claimable? -> {:error, :claim_not_available}
      blocked -> {:error, :itc_blocked}
      true -> :ok
    end
  end

  defp parse_ids(ids) when is_list(ids) and ids != [] and length(ids) <= 500 do
    parsed =
      Enum.map(ids, fn
        id when is_integer(id) and id > 0 ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {n, ""} when n > 0 -> n
            _ -> nil
          end

        _ ->
          nil
      end)

    if nil in parsed, do: {:error, :invalid_selection}, else: {:ok, Enum.sort(Enum.uniq(parsed))}
  end

  defp parse_ids(_), do: {:error, :invalid_selection}
end
