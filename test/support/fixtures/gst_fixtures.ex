defmodule Nila.GstFixtures do
  @moduledoc """
  Test helpers for working GST months through the real intake path: a dump is
  recorded and `DumpWorker` extracts + derives, exactly as production does.
  """
  use Oban.Testing, repo: Nila.Repo

  alias Nila.Gst.Intake.{DumpWorker, Dumps}
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
end
