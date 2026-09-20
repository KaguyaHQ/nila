defmodule Nila.GstFixtures do
  @moduledoc """
  Test helpers for working GST months through the real intake path: a dump is
  recorded and `DumpWorker` extracts + derives, exactly as production does.
  """
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Gst.Intake.{DumpWorker, Dumps}
  alias Nila.Gst.Purchase.{Reconciliation, Register, Resolutions}
  alias Nila.Storage

  @doc """
  Brings in one dump (`kind`: "sales" | "purchase" | "gstr2b") for
  `(org, client, period)` and runs the worker inline. Returns the dump.
  """
  def work_dump!(org, client, period, kind, bytes, user_id \\ nil) do
    key = "dumps/#{org.id}/#{client.id}/#{period}/#{kind}_#{System.unique_integer([:positive])}"
    {:ok, _} = Storage.put(key, bytes)

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user_id},
        %{period: period, kind: kind, file_keys: [key]}
      )

    :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})
    dump
  end

  @doc """
  Answers every open gating issue on a sales month the way a reviewer would.

  Blocking issues are not gating work and are never confirmed here — a month
  holding one stays unsignable, which is the point of the level.
  """
  def answer_sales_issues!(sales_month, user_id, opts \\ []) do
    skip = opts |> Keyword.get(:except, []) |> List.wrap()

    sales_month
    |> Nila.Gst.Sales.Review.Resolutions.workings()
    |> Map.fetch!(:issues)
    |> Enum.filter(
      &(&1["status"] == "open" and Nila.Gst.Issues.gating?(&1) and &1["code"] not in skip)
    )
    |> Enum.each(fn issue ->
      {:ok, _} =
        Nila.Gst.Sales.Review.Resolutions.record(
          sales_month,
          %{
            "verb" => "confirm_issue",
            "target" => Nila.Gst.Sales.Workings.issue_key(issue)
          },
          user_id
        )
    end)

    sales_month
  end

  @doc """
  Records an already-extracted GSTR-2B arrival, for tests that seed a month's
  reconciliation from disk rather than through the worker.

  The dumps table is where "has the portal snapshot arrived" is answered. A
  month seeded with a matched recon but no 2B row is incoherent, and the page
  reads it correctly: nothing has been reconciled against, so nothing in the
  register is a real decision yet.
  """
  def gstr2b_arrived!(org, client, period, invoices \\ []) do
    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: period, kind: "gstr2b", status: "extracted", invoices: invoices}
      )

    dump
  end

  @doc "Records the requested treatment for every outstanding invoice in a test month."
  def choose_itc_treatment!(month, scope, attrs) do
    ids =
      month
      |> Resolutions.workings()
      |> Map.fetch!(:case_lines)
      |> Enum.filter(
        &(&1.document_type in ~w(invoice debit_note) and
            Enum.sum(Map.values(&1.outstanding_heads)) > 0)
      )
      |> Enum.map(& &1.case_id)

    {:ok, %{month: month}} =
      Nila.Gst.Purchase.ItcDecisions.apply(scope, month.client_id, month.period, ids, attrs)

    month
  end

  @doc """
  Settles every open register row on a purchase month, so it can be signed.

  `Signoffs.sign_off/2` refuses a month holding unsettled rows, which is what a
  test seeding a real reconciliation runs into when its subject is the signature
  rather than the decisions. This records the audited outcome each open row
  would get from a reviewer — a confirmed pair where the engine offered a
  candidate, an accepted unmatched otherwise — rather than faking a clean
  summary, so the month reaches the signature the way a worked one does.
  """
  # Settling rebuckets: confirming a `needs_human` pair can land the row in
  # `value_mismatch`, and unwinding a pair can push its partner into
  # `in_books_not_2b`. One pass therefore settles a moving target, so this
  # repeats until the register stops producing open rows.
  def settle_register!(month, user_id, passes \\ 5) do
    workings = Resolutions.workings(month)
    remaining = Register.need_decision(workings.summary)

    cond do
      remaining == 0 ->
        month

      passes == 0 ->
        raise "settle_register! could not settle #{remaining} row(s): " <>
                inspect(
                  for row <- workings.rows,
                      Register.decision_row?(row),
                      do: {row["bucket"], row["invoice_number"]}
                )

      true ->
        # `value_mismatch` is absent on purpose: those rows are already paired,
        # the return takes the 2B figure, and no verb settles them because no
        # answer would change the filing.
        recon_attrs =
          for bucket <- ~w(needs_human in_books_not_2b in_2b_not_books),
              entry <- workings.recon[bucket] || [] do
            settle_attrs(bucket, entry)
          end

        block_attrs =
          for block <- workings.itc["blocks"] || [], block["state"] == "recommended" do
            %{"verb" => "allow_itc", "payload" => %{"block_id" => block["block_id"]}}
          end

        {:ok, result} =
          Resolutions.record_many_and_refresh(month, recon_attrs ++ block_attrs, user_id)

        result =
          result.workings.document_cases
          |> Enum.reject(&(&1.document_state in ~w(held not_held)))
          |> Enum.reduce(result, fn itc_case, current ->
            {:ok, next} =
              Resolutions.record_itc_case_event_and_refresh(
                current.month,
                itc_case.case_id,
                "client_holds_document",
                [],
                user_id
              )

            next
          end)

        settle_register!(result.month, user_id, passes - 1)
    end
  end

  defp settle_attrs("in_2b_not_books", entry) do
    ref = entry |> Map.get("gstr2b", entry) |> Reconciliation.gstr2b_ref()
    %{"verb" => "dismiss_2b", "gstr2b_ref" => ref}
  end

  defp settle_attrs(_bucket, entry) do
    books_id = get_in(entry, ["books", "id"])
    pair = List.first(entry["candidates"] || []) || entry["gstr2b"]

    if pair do
      %{
        "verb" => "confirm_pair",
        "books_id" => books_id,
        "gstr2b_ref" => Reconciliation.gstr2b_ref(pair)
      }
    else
      %{
        "verb" => "accept_unmatched",
        "books_id" => books_id,
        "payload" => %{"reason" => "await_2b"}
      }
    end
  end
end
