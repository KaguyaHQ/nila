defmodule Nila.DemoSessionTest do
  use Nila.DataCase, async: false

  alias Nila.DemoSession
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.{Month, Months}
  alias Nila.Gst.Sales.Review.Resolution

  setup do
    org = Nila.AccountsFixtures.org_fixture()
    {:ok, client} = DemoSession.setup(org.id)
    %{org: org, client: client, confirmation: "RESET #{org.id}/#{client.id}/2026-06"}
  end

  test "setup is idempotent and creates an empty, identified sales client", %{
    org: org,
    client: client
  } do
    assert {:ok, %{id: id}} = DemoSession.setup(org.id)
    assert id == client.id

    assert {:ok, %{reset_check: :ok, counts: %{months: 0, dumps: 0}}} =
             DemoSession.inspect_session(org.id, client.id)

    assert client.gstin == "33AEWPH4158J1Z3"
    assert client.chase_channel == "none"
  end

  test "reset archives the exact rows, preserves original files and other clients, and reruns cleanly",
       context do
    %{org: org, client: client, confirmation: confirmation} = context

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-06",
        invoices: [%{"id" => "demo"}]
      })

    source_key = "orgs/#{org.id}/demo-test/#{Ecto.UUID.generate()}.pdf"
    {:ok, _} = Nila.Storage.put(source_key, "original demo bytes")

    {:ok, dump} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-06",
        kind: "sales",
        status: "extracted",
        file_keys: [source_key]
      })

    resolution =
      Repo.insert!(%Resolution{
        org_id: org.id,
        sales_month_id: month.id,
        verb: "confirm_issue",
        target: "demo"
      })

    other_org = Nila.AccountsFixtures.org_fixture()
    {:ok, other_client} = DemoSession.setup(other_org.id)

    {:ok, other_month} =
      Months.upsert(%{org_id: other_org.id, client_id: other_client.id, period: "2026-06"})

    assert {:ok, %{backup_key: backup_key, removed: %{dumps: 1, months: 1, resolutions: 1}}} =
             DemoSession.reset(org.id, client.id, confirmation)

    assert {:ok, bytes} = Nila.Storage.get(backup_key)
    archived = :erlang.binary_to_term(bytes, [:safe])
    assert Enum.map(archived.rows.dumps, & &1.id) == [dump.id]
    assert Enum.map(archived.rows.resolutions, & &1.id) == [resolution.id]
    assert Repo.get(Month, month.id) == nil
    assert Repo.get(Dump, dump.id) == nil
    assert Repo.get!(Month, other_month.id).id == other_month.id
    assert Repo.get!(Nila.Clients.Client, client.id).gstin == client.gstin
    assert {:ok, "original demo bytes"} = Nila.Storage.get(source_key)
    assert {:ok, %{backup_key: nil}} = DemoSession.reset(org.id, client.id, confirmation)
    assert :ok = Nila.Storage.delete(backup_key)
    assert :ok = Nila.Storage.delete(source_key)
  end

  test "refuses wrong scope, missing confirmation and an ordinary client", %{
    org: org,
    client: client,
    confirmation: confirmation
  } do
    assert {:error, :confirmation_mismatch} = DemoSession.reset(org.id, client.id, "")
    assert {:error, :not_found} = DemoSession.inspect_session(org.id + 100_000, client.id)
    client |> Ecto.Changeset.change(match_hints: []) |> Repo.update!()

    assert {:error, :not_the_disposable_demo_client} =
             DemoSession.reset(org.id, client.id, confirmation)
  end

  test "refuses another period and filed state", %{
    org: org,
    client: client,
    confirmation: confirmation
  } do
    {:ok, month} = Months.upsert(%{org_id: org.id, client_id: client.id, period: "2026-05"})

    assert {:error, :contains_other_or_filed_month} =
             DemoSession.reset(org.id, client.id, confirmation)

    month |> Ecto.Changeset.change(period: "2026-06", state: "filed") |> Repo.update!()

    assert {:error, :contains_other_or_filed_month} =
             DemoSession.reset(org.id, client.id, confirmation)
  end

  test "refuses signed work and unfinished extraction", %{
    org: org,
    client: client,
    confirmation: confirmation
  } do
    {:ok, month} = Months.upsert(%{org_id: org.id, client_id: client.id, period: "2026-06"})
    user = Nila.AccountsFixtures.user_fixture()

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        org_id: org.id,
        sales_month_id: month.id,
        artifact: "gstr1",
        signed_by_id: user.id,
        snapshot: %{}
      })

    assert {:error, :contains_signoff} = DemoSession.reset(org.id, client.id, confirmation)
    Repo.delete!(signoff)

    {:ok, dump} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-06",
        kind: "sales",
        status: "extracted"
      })

    {:ok, _job} = Oban.insert(Nila.Gst.Intake.DumpWorker.new(%{dump_id: dump.id}))
    assert {:error, :processing_not_finished} = DemoSession.reset(org.id, client.id, confirmation)
    assert Repo.get!(Dump, dump.id).id == dump.id
  end
end
