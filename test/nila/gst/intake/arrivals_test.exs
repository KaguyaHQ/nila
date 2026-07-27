defmodule Nila.Gst.Intake.ArrivalsTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Intake.{Arrival, Arrivals, DumpWorker, Dumps}
  alias Nila.Gst.Purchase.Months, as: ClientMonths

  # October 2025, because that is when the purchase stub's bills are dated: a
  # packet whose contents disagree with its period never reaches the wall check
  # (`Nila.Gst.Intake.Preconditions`), and this test is about the wall.
  @period "2025-10"

  setup do
    %{user: user, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Ravi Traders", type: "company"})

    %{
      user: user,
      org: org,
      client: client,
      scope: %Scope{user: user, current_org: org, membership: membership}
    }
  end

  test "routes a pending arrival into a dump and enqueues the existing worker", context do
    arrival = arrival!(context, "one.pdf")

    assert {:ok, dump} =
             Arrivals.route(arrival, %{
               client_id: context.client.id,
               period: @period,
               kind: "purchase",
               brought_in_by_id: context.user.id
             })

    assert dump.file_keys == [arrival.storage_key]
    assert String.starts_with?(arrival.storage_key, "orgs/#{context.org.id}/arrivals/")
    assert String.ends_with?(arrival.storage_key, "/original.pdf")
    refute arrival.storage_key =~ "one.pdf"
    assert_enqueued(worker: DumpWorker, args: %{dump_id: dump.id})

    routed = Repo.get!(Arrival, arrival.id)
    assert routed.status == "routed"
    assert routed.routed_dump_id == dump.id
  end

  test "files from one sender route together as one dump", context do
    first = arrival!(context, "one.pdf")
    second = arrival!(context, "two.pdf")

    assert {:ok, dump} =
             Arrivals.route_many([first, second], %{
               client_id: context.client.id,
               period: @period,
               kind: "sales",
               brought_in_by_id: context.user.id
             })

    assert MapSet.new(dump.file_keys) == MapSet.new([first.storage_key, second.storage_key])
    assert Enum.all?([first, second], &(Repo.get!(Arrival, &1.id).status == "routed"))
  end

  test "routing onto a signed month still lets DumpWorker hold the dump", context do
    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: context.org.id,
        client_id: context.client.id,
        period: @period,
        state: "worked",
        register_rows: [],
        recon: %{
          "matched" => [],
          "value_mismatch" => [],
          "needs_human" => [],
          "in_books_not_2b" => [],
          "in_2b_not_books" => []
        },
        summary: %{"buckets" => %{"matched" => 0}}
      })

    assert {:ok, _signoff} = Signoffs.sign_off(month, context.scope)
    arrival = arrival!(context, "late.pdf")

    assert {:ok, dump} =
             Arrivals.route(arrival, %{
               client_id: context.client.id,
               period: @period,
               kind: "purchase",
               brought_in_by_id: context.user.id
             })

    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})
    assert {:ok, %{status: "held"}} = Dumps.fetch(context.org.id, dump.id)
  end

  defp arrival!(context, filename) do
    {:ok, arrival} =
      Arrivals.ingest(
        %{org_id: context.org.id, client_id: context.client.id},
        %{
          source: "email",
          sender: "ravi@example.com",
          filename: filename,
          content_type: "application/pdf",
          bytes: "%PDF-1.4 fake"
        }
      )

    arrival
  end
end
