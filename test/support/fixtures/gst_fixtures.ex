defmodule Nila.GstFixtures do
  @moduledoc """
  Test helpers for working GST months through the real intake path: a dump is
  recorded and `DumpWorker` extracts + derives, exactly as production does.
  """
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Gst.Intake.{Confirmations, DumpWorker, Dumps}
  alias Nila.{Repo, Storage}

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

  @doc "Records an explicit client-yes event after the test's sales intake is complete."
  def confirm_sales_complete!(org, client, period) do
    client =
      if client.phone do
        client
      else
        client |> Ecto.Changeset.change(phone: "919876543210") |> Repo.update!()
      end

    {:ok, confirmation} =
      Confirmations.record_client(
        %{org_id: org.id},
        client.id,
        period,
        %{
          decision: "client_yes",
          channel: "whatsapp",
          source_ref: "fixture:#{System.unique_integer([:positive])}",
          actor_phone: client.phone
        }
      )

    confirmation
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
end
