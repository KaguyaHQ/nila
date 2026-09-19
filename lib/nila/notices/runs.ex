defmodule Nila.Notices.Runs do
  @moduledoc "Persistent firm-wide checks. Opening results never resets what is new."
  import Ecto.Query
  alias Nila.{Notices, Repo}
  alias Nila.Accounts.Policy
  alias Nila.Notices.{Notice, Run, RunWorker}

  def latest(org_id) do
    Repo.one(from r in Run, where: r.org_id == ^org_id, order_by: [desc: r.id], limit: 1)
    |> reconcile_jobs()
  end

  def pending?(nil), do: false
  def pending?(run), do: Enum.any?(run.results, fn {_, r} -> r["state"] == "pending" end)

  def start(scope) do
    if Policy.can?(scope, :edit_records) do
      Repo.transact(fn ->
        # Serialize double clicks and checks started by another member of the firm.
        Repo.one!(
          from o in Nila.Orgs.Org, where: o.id == ^scope.current_org.id, lock: "FOR UPDATE"
        )

        previous = latest(scope.current_org.id)

        cond do
          pending?(previous) ->
            {:ok, previous}

          true ->
            checks = Notices.client_checks(scope.current_org.id)

            baseline =
              Repo.one(
                from n in Notice,
                  join: c in assoc(n, :client),
                  where: c.org_id == ^scope.current_org.id,
                  select: max(n.id)
              ) || 0

            run = Repo.insert!(%Run{org_id: scope.current_org.id, baseline_notice_id: baseline})
            results = Map.new(checks, &{to_string(&1.id), queue(run, &1)})
            {:ok, Repo.update!(Ecto.Changeset.change(run, results: results))}
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  def retry(scope) do
    if Policy.can?(scope, :edit_records) do
      Repo.transact(fn ->
        Repo.one!(
          from o in Nila.Orgs.Org, where: o.id == ^scope.current_org.id, lock: "FOR UPDATE"
        )

        case latest(scope.current_org.id) do
          nil -> {:error, :not_found}
          run -> retry_locked(run, scope)
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  defp retry_locked(run, scope) do
    run = Repo.one!(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE") |> reconcile_jobs()
    checks = Map.new(Notices.client_checks(scope.current_org.id), &{to_string(&1.id), &1})

    results =
      Map.new(run.results, fn {id, result} ->
        if result["state"] in ["checked", "pending"] do
          {id, result}
        else
          {id,
           if(checks[id],
             do: queue(run, checks[id]),
             else: Map.merge(result, %{"state" => "failed", "reason" => "Client removed"})
           )}
        end
      end)

    {:ok, Repo.update!(Ecto.Changeset.change(run, results: results))}
  end

  defp queue(run, check) do
    result = %{"name" => check.client.name, "gstin" => check.client.gstin}

    reason =
      case check.state do
        :missing_gstin -> "GSTIN missing"
        :not_connected -> "Connect GST"
        :expired -> "Reconnect GST"
        :checking -> "Check already running. Retry when finished."
        _ -> nil
      end

    if reason do
      Map.merge(result, %{"state" => "failed", "reason" => reason})
    else
      job =
        %{run_id: run.id, org_id: run.org_id, client_id: check.id}
        |> RunWorker.new()
        |> Oban.insert!()

      Map.merge(result, %{"state" => "pending", "job_id" => job.id})
    end
  end

  def perform(run_id, client_id, job_id) do
    run = Repo.get!(Run, run_id)
    result = run.results[to_string(client_id)]

    if result && result["state"] == "pending" && result["job_id"] == job_id do
      outcome =
        with {:ok, client} <- Nila.Clients.get_client(run.org_id, client_id),
             true <- client.gstin == result["gstin"] do
          Notices.sync(run.org_id, client_id)
        else
          _ -> {:error, :invalid_account}
        end

      finish(run_id, client_id, job_id, outcome)
    end

    :ok
  end

  def finish(run_id, client_id, job_id, outcome) do
    Repo.transact(fn ->
      run = Repo.one!(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")
      key = to_string(client_id)
      result = run.results[key]

      if result && result["state"] == "pending" && result["job_id"] == job_id do
        {result, ids} =
          case outcome do
            {:ok, _} ->
              ids =
                Repo.all(
                  from n in Notice,
                    where:
                      n.client_id == ^client_id and n.gstin == ^result["gstin"] and
                        n.id > ^run.baseline_notice_id,
                    select: n.id
                )

              {Map.merge(result, %{"state" => "checked", "reason" => nil}), ids}

            {:error, reason} ->
              {Map.merge(result, %{"state" => "failed", "reason" => Notices.error_message(reason)}),
               []}
          end

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(run,
             results: Map.put(run.results, key, result),
             notice_ids: Enum.uniq(run.notice_ids ++ ids)
           )
         )}
      else
        {:ok, run}
      end
    end)
  end

  # A killed/cancelled job must not leave the screen saying "checking" forever.
  defp reconcile_jobs(nil), do: nil

  defp reconcile_jobs(run) do
    ids = for {_, r} <- run.results, r["state"] == "pending", do: r["job_id"]
    jobs = Repo.all(from j in Oban.Job, where: j.id in ^ids, select: {j.id, j.state}) |> Map.new()

    results =
      Map.new(run.results, fn {id, result} ->
        if result["state"] == "pending" &&
             jobs[result["job_id"]] not in ["available", "scheduled", "executing", "retryable"] do
          {id, Map.merge(result, %{"state" => "failed", "reason" => "Check interrupted. Retry."})}
        else
          {id, result}
        end
      end)

    %{run | results: results}
  end
end
