defmodule NilaWeb.SalesUploadRemovalControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  import Ecto.Query
  import Nila.GstFixtures
  alias Nila.{Clients, Repo}
  alias Nila.Gst.Sales.{Batch, Derivation, Months, Uploads}
  alias Nila.Gst.Sales.Review.Resolutions

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    dump = work_dump!(org, client, "2025-10", "sales", "%PDF-original", user.id) |> Repo.reload!()
    {:ok, batch} = Batch.create(org.id, client.id, Ecto.UUID.generate())
    dump = dump |> Ecto.Changeset.change(sales_batch_id: batch.id) |> Repo.update!()
    {:ok, :ok} = Repo.transact(fn -> {:ok, Derivation.refresh_in_transaction(dump)} end)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      dump: dump,
      ids: Enum.map(dump.invoices, & &1["id"]),
      path: "/api/workspace/sales/#{client.id}/2025-10/uploads/#{dump.id}/removal"
    }
  end

  test "remove and restore retain originals, change working totals and keep an audit history",
       c do
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2025-10")
    assert Resolutions.workings(month).invoices != []

    assert c.conn
           |> post(c.path, %{action: "remove", source_ids: c.ids})
           |> contract_response(200) == %{"ok" => true}

    assert Resolutions.workings(Repo.reload!(month)).invoices == []
    saved = Repo.reload!(c.dump)
    assert saved.file_keys == c.dump.file_keys
    assert saved.invoices == c.dump.invoices
    assert [%{"action" => "remove", "actor_id" => actor}] = saved.meta["removal_history"]
    assert actor == c.user.id
    [history] = Uploads.history(c.org.id, c.client.id, "2025-10").batches
    assert history.active_invoice_ids == []
    assert Enum.map(history.removed_invoices, & &1.id) == c.ids
    # Repeated confirmation does not duplicate history or change another invoice.
    c.conn |> post(c.path, %{action: "remove", source_ids: c.ids}) |> contract_response(200)
    assert length(Repo.reload!(c.dump).meta["removal_history"]) == 1

    c.conn
    |> post(c.path, %{action: "restore", source_ids: [hd(c.ids)]})
    |> contract_response(200)

    assert length(Resolutions.workings(Repo.reload!(month)).invoices) == 1
    c.conn |> post(c.path, %{action: "restore", source_ids: c.ids}) |> contract_response(200)
    assert length(Resolutions.workings(Repo.reload!(month)).invoices) == length(c.ids)
    assert Enum.at(Repo.reload!(c.dump).meta["removal_history"], 1)["action"] == "restore"
  end

  test "an invalid source makes the whole request fail without partial removal", c do
    c.conn
    |> post(c.path, %{action: "remove", source_ids: c.ids ++ ["foreign"]})
    |> contract_response(404)

    [history] = Uploads.history(c.org.id, c.client.id, "2025-10").batches
    assert history.active_invoice_ids == c.ids
    c.conn |> post(c.path, %{action: "erase", source_ids: c.ids}) |> contract_response(400)
  end

  test "filed work cannot be removed or restored", c do
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2025-10")

    month
    |> Ecto.Changeset.change(filed_at: DateTime.utc_now())
    |> Repo.update!()

    for action <- ~w(remove restore),
        do: c.conn |> post(c.path, %{action: action, source_ids: c.ids}) |> contract_response(409)
  end

  test "an upload still being read cannot be removed", c do
    c.dump |> Ecto.Changeset.change(status: "extracting") |> Repo.update!()
    c.conn |> post(c.path, %{action: "remove", source_ids: c.ids}) |> contract_response(409)
  end

  test "another firm's user cannot remove these invoices", c do
    %{user: outsider} = user_with_org_fixture()

    build_conn()
    |> log_in_user(outsider)
    |> post(c.path, %{action: "remove", source_ids: c.ids})
    |> contract_response(404)
  end

  test "viewers cannot remove or restore invoices", c do
    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.org_id == ^c.org.id and m.user_id == ^c.user.id),
      set: [role: "viewer"]
    )

    for action <- ~w(remove restore),
        do: c.conn |> post(c.path, %{action: action, source_ids: c.ids}) |> contract_response(403)
  end
end
