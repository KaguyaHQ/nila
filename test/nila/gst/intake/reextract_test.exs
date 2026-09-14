defmodule Nila.Gst.Intake.ReextractTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Nila.AccountsFixtures
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker, ExtractionAttempts, Reextract}
  alias Nila.Gst.Sales.{Month, Months}
  alias Nila.Gst.Sales.Invoice.Correction
  alias Nila.Gst.Sales.Review.Resolutions
  alias Nila.{Clients, Repo, Storage}

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Reread test",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "reread-test/#{org.id}/original.pdf"
    {:ok, _} = Storage.put(key, "%PDF test")

    {:ok, dump} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        kind: "sales",
        period: "2025-10",
        file_keys: [key]
      })

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})
    {:ok, dump} = Dumps.fetch(org.id, dump.id)
    {:ok, month} = Months.get_by_period(org.id, client.id, dump.period)
    previous = Application.fetch_env!(:nila, :sales_extractor)
    Application.put_env(:nila, :sales_extractor, Nila.Gst.Extraction.Sales.RereadStub)
    on_exit(fn -> Application.put_env(:nila, :sales_extractor, previous) end)
    %{dump: dump, month: month, user: user}
  end

  test "rereads the same upload without cached artifacts or progressive writes", %{
    dump: dump,
    month: month
  } do
    assert {:ok, first} = Reextract.run(dump.org_id, dump.id)
    assert_receive {:reread_options, opts}

    for key <- [:on_invoice, :on_segments, :completed_artifacts, :resume_segments] do
      refute Keyword.has_key?(opts, key)
    end

    assert first.file_keys == dump.file_keys
    assert Enum.map(first.invoices, & &1["id"]) == Enum.map(dump.invoices, & &1["id"])
    assert Repo.get!(Month, month.id).invoices != []
    assert {:ok, second} = Reextract.run(dump.org_id, dump.id)
    assert second.id == dump.id
    # fresh, separately stored page images
    assert second.invoices != first.invoices
    assert Repo.aggregate(from(d in Dump, where: d.org_id == ^dump.org_id), :count) == 1
    assert length(ExtractionAttempts.list_for_dump(dump.id)) == 2
    assert Enum.all?(ExtractionAttempts.list_for_dump(dump.id), &(&1.status == "succeeded"))
    assert {:ok, "%PDF test"} = Storage.get(hd(second.file_keys))
  end

  test "failed reads preserve both saved upload and month", %{dump: dump, month: month} do
    Process.put(:reread_callback, fn -> {:error, :provider_down} end)
    assert {:error, :provider_down} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id) == dump
    assert Repo.get!(Month, month.id) == month
    assert [%{status: "failed"}] = ExtractionAttempts.list_for_dump(dump.id)
  end

  test "exceptions also leave the saved answer untouched", %{dump: dump} do
    Process.put(:reread_callback, fn -> raise "provider crash" end)
    assert_raise RuntimeError, "provider crash", fn -> Reextract.run(dump.org_id, dump.id) end
    assert Repo.get!(Dump, dump.id) == dump
  end

  test "reviewed months refuse a call", %{dump: dump, month: month} do
    month |> Month.changeset(%{state: "reviewed"}) |> Repo.update!()
    assert {:error, :reviewed_or_filed} = Reextract.run(dump.org_id, dump.id)
    refute_received {:reread_options, _}
  end

  test "source corrections refuse a call", %{dump: dump} do
    correction!(dump)
    assert {:error, :human_decisions} = Reextract.run(dump.org_id, dump.id)
    refute_received {:reread_options, _}
  end

  test "a correction made during extraction prevents promotion", %{dump: dump, month: month} do
    Process.put(:reread_callback, fn ->
      correction!(dump)
      :ok
    end)

    assert {:error, :human_decisions} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id) == dump
    assert Repo.get!(Month, month.id) == month
  end

  test "month decisions made during extraction prevent promotion", %{
    dump: dump,
    month: month,
    user: user
  } do
    Process.put(:reread_callback, fn ->
      {:ok, _} =
        Resolutions.record(month, %{verb: "confirm_issue", target: "test", payload: %{}}, user.id)

      :ok
    end)

    assert {:error, :human_decisions} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id) == dump
  end

  test "a changed upload cannot be overwritten by an older read", %{dump: dump} do
    Process.put(:reread_callback, fn ->
      dump |> Dump.changeset(%{meta: %{"changed" => true}}) |> Repo.update!()
      :ok
    end)

    assert {:error, :upload_changed} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id).meta == %{"changed" => true}
  end

  test "organization boundary is enforced", %{dump: dump} do
    assert {:error, :not_found} = Reextract.run(dump.org_id + 999, dump.id)
    refute_received {:reread_options, _}
  end

  test "an incomplete read cannot erase the old invoices", %{dump: dump} do
    Process.put(:reread_callback, fn -> {:ok, %{pages: [], images: %{}}} end)
    assert {:error, :incomplete_read} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id) == dump
  end

  test "filing during a read prevents replacement", %{dump: dump, month: month} do
    Process.put(:reread_callback, fn ->
      month |> Month.changeset(%{state: "filed"}) |> Repo.update!()
      :ok
    end)

    assert {:error, :reviewed_or_filed} = Reextract.run(dump.org_id, dump.id)
    assert Repo.get!(Dump, dump.id) == dump
    assert Repo.get!(Month, month.id).state == "filed"
  end

  test "removed invoices cannot return through a reread", %{dump: dump, user: user} do
    Repo.insert!(%Nila.Gst.Sales.Invoice.Removal{
      org_id: dump.org_id,
      client_id: dump.client_id,
      batch_ref: to_string(dump.id),
      source_id: hd(dump.invoices)["id"],
      removed_by_id: user.id,
      removed_at: DateTime.utc_now()
    })

    assert {:error, :human_decisions} = Reextract.run(dump.org_id, dump.id)
    refute_received {:reread_options, _}
  end

  defp correction!(dump) do
    Repo.insert!(%Correction{
      org_id: dump.org_id,
      client_id: dump.client_id,
      batch_ref: to_string(dump.id),
      source_id: hd(dump.invoices)["id"],
      field_path: "invoice_number",
      payload: %{"from" => "old", "to" => "new"}
    })
  end
end
